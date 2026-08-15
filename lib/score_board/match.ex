defmodule ScoreBoard.Match do
  @moduledoc """
  The source of truth for a single live match.

  Exactly one instance runs somewhere in the cluster, placed by Horde. It
  owns the running score, writes it through to `ScoreBoard.DB` on every
  goal, and broadcasts events that per-node `ScoreBoard.Board`s derive
  their copies from.

  On (re)start - including a Horde failover or rebalance to another node -
  `init/1` reads the score back from the DB and announces itself with
  `{:match_created, id, score}`, so every board refreshes its row. The read
  must succeed: a missing or unreachable DB entry crashes the match rather
  than resurrecting it with a guessed score.
  """
  use GenServer, restart: :transient

  alias ScoreBoard.DB
  alias ScoreBoard.EchoPubSub
  alias ScoreBoard.Matches

  @topic "matches:events"

  @type team :: :home | :away
  @type score :: %{home: non_neg_integer(), away: non_neg_integer()}

  @spec start_link(Matches.match_id()) :: GenServer.on_start()
  def start_link(id) do
    GenServer.start_link(__MODULE__, id, name: Matches.via(id))
  end

  @doc """
  Topic carrying `{:match_created, id, score}` and `{:goal, id, team}`
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
    :ok = EchoPubSub.broadcast(@topic, {:match_created, id, score})
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
    {:ok, score} = DB.read(id)
    score
  end
end
