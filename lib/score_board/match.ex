defmodule ScoreBoard.Match do
  @moduledoc """
  Authoritative process for a single match.

  Exactly one instance runs somewhere in the cluster, placed by Horde. It
  owns the true score; per-node `ScoreBoard.Board`s only derive it from the
  events this process broadcasts on `topic/0`.

  If the owning node dies, Horde restarts the match on a surviving node,
  where `init/1` re-seeds the score from that node's derived board — the
  best information available without a persistence layer (stale if that
  board had missed events).
  """
  use GenServer, restart: :transient

  alias ScoreBoard.Board
  alias ScoreBoard.Matches

  @topic "matches:events"

  @type team :: :home | :away
  @type score :: %{home: non_neg_integer(), away: non_neg_integer()}

  @spec start_link(Matches.match_id()) :: GenServer.on_start()
  def start_link(id) do
    GenServer.start_link(__MODULE__, id, name: Matches.via(id))
  end

  @doc "Topic carrying `{:match_created, id}` and `{:goal, id, team}` events."
  @spec topic() :: String.t()
  def topic, do: @topic

  @impl GenServer
  def init(id) do
    score =
      case Board.fetch_score(id) do
        {:ok, restored} -> restored
        :error -> %{home: 0, away: 0}
      end

    :ok = Phoenix.PubSub.broadcast(ScoreBoard.PubSub, @topic, {:match_created, id})
    {:ok, %{id: id, score: score}}
  end

  @impl GenServer
  def handle_call({:goal, team}, _from, state) when team in [:home, :away] do
    state = update_in(state.score[team], &(&1 + 1))

    :ok = Phoenix.PubSub.broadcast(ScoreBoard.PubSub, @topic, {:goal, state.id, team})
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_call(:score, _from, state) do
    {:reply, {:ok, state.score}, state}
  end
end
