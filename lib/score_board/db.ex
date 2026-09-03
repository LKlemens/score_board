defmodule ScoreBoard.DB do
  @moduledoc """
  A replicated, in-memory store of the latest score per match - one replica
  per node, so no single failure loses data.

  Every node runs its own `ScoreBoard.DB` under the application tree. Reads
  are local and always available; a write applies locally and fans out to
  the peer replicas over raw distribution (`GenServer.abcast`), which stays
  reliable regardless of the PubSub-layer blip the demo injects. Goals only
  ever increment, so replicas reconcile by componentwise max - a
  conflict-free join that converges no matter the message order.

  Replicas gossip their full state on startup and whenever a node joins:
  the newcomer asks peers to push their scores and max-merges the replies,
  then tells the boards to reload so they backfill any rows they missed.
  """
  use GenServer

  alias ScoreBoard.EchoPubSub
  alias ScoreBoard.Match
  alias ScoreBoard.Matches

  require Logger

  @name __MODULE__

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: @name)
  end

  @doc "Whether this node's replica is running."
  @spec alive?() :: boolean()
  def alive?, do: is_pid(Process.whereis(@name))

  @doc "The stored score for a match, read from the local replica."
  @spec read(Matches.match_id()) :: {:ok, Match.score()} | :error
  def read(id), do: GenServer.call(@name, {:read, id})

  @doc "Stores the latest score for a match and replicates it to the peers."
  @spec write(Matches.match_id(), Match.score()) :: :ok
  def write(id, score), do: GenServer.call(@name, {:write, id, score})

  @doc "All stored scores, keyed by match id, from the local replica."
  @spec all() :: %{Matches.match_id() => Match.score()}
  def all, do: GenServer.call(@name, :all)

  @impl GenServer
  def init(:ok) do
    Logger.warning("DB replica starting on #{node()}")
    # Future topology changes drive re-sync; existing peers are pulled once
    # in handle_continue below.
    :net_kernel.monitor_nodes(true)
    {:ok, %{}, {:continue, :request_sync}}
  end

  # Ask every already-connected peer to push its scores. A cast, not a call,
  # so two replicas booting at once cannot deadlock waiting on each other.
  @impl GenServer
  def handle_continue(:request_sync, scores) do
    request_sync(Node.list())
    {:noreply, scores}
  end

  @impl GenServer
  def handle_call({:read, id}, _from, scores) do
    {:reply, Map.fetch(scores, id), scores}
  end

  def handle_call({:write, id, score}, _from, scores) do
    # Peers get the raw value and merge it themselves; abcast excludes us,
    # so we merge our own copy here.
    GenServer.abcast(Node.list(), @name, {:replicate, id, score})
    {:reply, :ok, merge_one(scores, id, score)}
  end

  def handle_call(:all, _from, scores) do
    {:reply, scores, scores}
  end

  @impl GenServer
  def handle_cast({:replicate, id, score}, scores) do
    {:noreply, merge_one(scores, id, score)}
  end

  # A peer (re)joined and asked us to send what we have.
  def handle_cast({:sync_request, from}, scores) do
    GenServer.cast({@name, from}, {:merge_all, scores})
    {:noreply, scores}
  end

  # A peer's full state arrived; max-merge it and, if it added anything, tell
  # the boards to reload so they backfill the newly learned rows.
  def handle_cast({:merge_all, remote}, scores) do
    merged = merge_all(scores, remote)
    if merged != scores, do: EchoPubSub.broadcast(Match.topic(), :db_merged)
    {:noreply, merged}
  end

  @impl GenServer
  def handle_info({:nodeup, peer}, scores) do
    GenServer.cast({@name, peer}, {:sync_request, node()})
    {:noreply, scores}
  end

  def handle_info({:nodedown, _peer}, scores), do: {:noreply, scores}

  defp request_sync(peers) do
    for peer <- peers, do: GenServer.cast({@name, peer}, {:sync_request, node()})
  end

  defp merge_one(scores, id, score) do
    Map.update(scores, id, score, &max_score(&1, score))
  end

  defp merge_all(scores, remote) do
    Map.merge(scores, remote, fn _id, a, b -> max_score(a, b) end)
  end

  # Goal counters only ever increment, so componentwise max cannot lose
  # goals, whichever replica was further ahead.
  defp max_score(a, b), do: %{home: max(a.home, b.home), away: max(a.away, b.away)}
end
