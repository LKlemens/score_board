defmodule ScoreBoard.Match do
  @moduledoc """
  The source of truth for a single live match in one lane.

  Exactly one instance per lane runs somewhere in the cluster, placed by
  Horde. It owns the running score, writes it through to the lane's
  `ScoreBoard.DB` replica on every goal, and broadcasts events on the lane's
  event bus that per-node `ScoreBoard.Board`s derive their copies from.

  On (re)start - including a Horde failover or rebalance to another node -
  it waits for the DB to be resolvable, reads the score back, and announces
  itself with `{:match_created, id, score, pid}`, so every board of that lane
  refreshes its row.
  """
  use GenServer, restart: :transient

  alias ScoreBoard.Board
  alias ScoreBoard.DB
  alias ScoreBoard.EchoPubSub
  alias ScoreBoard.Lane
  alias ScoreBoard.Matches

  require Logger

  @topic "matches:events"

  # A restart can outrun the write that seeded this match's row into the
  # local replica; poll briefly before giving up on it.
  @restore_retries 20
  @restore_delay 50

  @type team :: :home | :away
  @type score :: %{home: non_neg_integer(), away: non_neg_integer()}

  # The index is placement-only (see ScoreBoard.RoundRobinDistribution).
  @spec start_link({Lane.id(), Matches.match_id(), non_neg_integer()}) :: GenServer.on_start()
  def start_link({lane, id, _index}) do
    GenServer.start_link(__MODULE__, {lane, id}, name: Matches.via(lane, id))
  end

  @doc """
  Topic carrying `{:match_created, id, score, pid}` and `{:goal, id, team}`
  events - on the lane's EchoPubSub instance, because these events must not
  be lost.
  """
  @spec topic() :: String.t()
  def topic, do: @topic

  @impl GenServer
  def init({lane, id}) do
    # Trap exits so a Horde registry name conflict arrives as a message
    # instead of crash-looping the supervisor through restart intensity.
    Process.flag(:trap_exit, true)

    # Keep init non-blocking; the restore can poll for up to a second.
    {:ok, %{lane: lane, id: id, score: nil}, {:continue, :restore}}
  end

  @impl GenServer
  def handle_continue(:restore, state) do
    score = restore_score(state.lane, state.id)
    # Carry the pid so boards monitor the exact process without racing the registry.
    :ok = broadcast(state.lane, {:match_created, state.id, score, self()})
    {:noreply, %{state | score: score}}
  end

  @impl GenServer
  def handle_call({:goal, team}, _from, state) when team in [:home, :away] do
    state = update_in(state.score[team], &(&1 + 1))

    _ = DB.write(state.lane, state.id, state.score)
    :ok = broadcast(state.lane, {:goal, state.id, team})
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_call(:score, _from, state) do
    {:reply, {:ok, state.score}, state}
  end

  @impl GenServer
  def handle_info({:EXIT, _pid, {:name_conflict, _key_value, _registry, _winner}}, state) do
    # A duplicate of this match registered elsewhere and this copy lost.
    # The score is already in the DB, so just stop.
    {:stop, :normal, state}
  end

  def handle_info({:EXIT, _pid, reason}, state) do
    {:stop, reason, state}
  end

  defp broadcast(lane, event) do
    EchoPubSub.broadcast(Lane.pubsub(lane), @topic, event)
  end

  # Reads this match's score from the lane's local replica, retrying to ride
  # out replication lag after a restart. Falls back to the board's derived
  # score, then to 0:0, rather than crash-looping when no row ever lands.
  defp restore_score(lane, id, retries \\ @restore_retries)

  defp restore_score(lane, id, 0) do
    case Board.fetch_score(lane, id) do
      {:ok, score} ->
        score

      :error ->
        Logger.warning("No DB or board score for match #{inspect(id)}; starting from 0:0")
        %{home: 0, away: 0}
    end
  end

  defp restore_score(lane, id, retries) do
    case DB.read(lane, id) do
      {:ok, score} ->
        score

      :error ->
        Process.sleep(@restore_delay)
        restore_score(lane, id, retries - 1)
    end
  end
end
