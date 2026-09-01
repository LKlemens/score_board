defmodule ScoreBoard.Match do
  @moduledoc """
  The source of truth for a single live match.

  Exactly one instance runs somewhere in the cluster, placed by Horde. It
  owns the running score, writes it through to `ScoreBoard.DB` on every
  goal, and broadcasts events that per-node `ScoreBoard.Board`s derive
  their copies from.

  On (re)start - including a Horde failover or rebalance to another node -
  `init/1` waits for the DB to be resolvable, reads the score back, and
  announces itself with `{:match_created, id, score, pid}`, so every board refreshes
  its row. A reachable DB with no row for the match is a genuine error and
  crashes it rather than resurrecting it with a guessed score.
  """
  use GenServer, restart: :transient

  alias ScoreBoard.DB
  alias ScoreBoard.EchoPubSub
  alias ScoreBoard.Matches

  @topic "matches:events"

  @type team :: :home | :away
  @type score :: %{home: non_neg_integer(), away: non_neg_integer()}

  # The index is placement-only (see ScoreBoard.RoundRobinDistribution) and
  # is ignored here - init/1 works from the id alone.
  @spec start_link({Matches.match_id(), non_neg_integer()}) :: GenServer.on_start()
  def start_link({id, _index}) do
    GenServer.start_link(__MODULE__, id, name: Matches.via(id))
  end

  @doc """
  Topic carrying `{:match_created, id, score, pid}` and `{:goal, id, team}`
  events - on `ScoreBoard.EchoPubSub`, because these events must not be
  lost.
  """
  @spec topic() :: String.t()
  def topic, do: @topic

  @impl GenServer
  def init(id) do
    # Trap exits so a Horde registry name conflict arrives as a message
    # instead of crash-looping the supervisor through restart intensity.
    Process.flag(:trap_exit, true)

    score = restore_score(id)
    # Carry the pid so boards monitor the exact process without racing the registry.
    :ok = EchoPubSub.broadcast(@topic, {:match_created, id, score, self()})
    {:ok, %{id: id, score: score}}
  end

  @impl GenServer
  def handle_call({:goal, team}, _from, state) when team in [:home, :away] do
    state = update_in(state.score[team], &(&1 + 1))

    _ = DB.write(state.id, state.score)
    :ok = EchoPubSub.broadcast(@topic, {:goal, state.id, team})
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_call(:score, _from, state) do
    {:reply, {:ok, state.score}, state}
  end

  @impl GenServer
  def handle_info({:EXIT, _pid, {:name_conflict, _key_value, _registry, _winner}}, state) do
    # A duplicate of this match registered elsewhere and this copy lost.
    # The score is already in the DB, so just stop
    {:stop, :normal, state}
  end

  def handle_info({:EXIT, _pid, reason}, state) do
    {:stop, reason, state}
  end

  defp restore_score(id) do
    # A match can start on a just-joined node (Horde redistribution/failover)
    # whose registry has not synced the DB yet; wait for it to be resolvable
    # so a transient miss does not look like an absent row. A reachable DB with
    # no row is a genuine error and still crashes - matches are seeded first.
    :ok = DB.await_ready()
    {:ok, score} = DB.read(id) |> dbg()
    score
  end
end
