defmodule ScoreBoard.DB do
  @moduledoc """
  A replicated, in-memory store of the latest score per match - one replica
  per node per lane, so no single failure loses data and lanes never share
  state.

  Every node runs one replica per lane under the lane pool. Reads are local
  and always available; a write applies locally and fans out to the peer
  replicas of the same lane over raw distribution (`GenServer.abcast`), which
  stays reliable regardless of the PubSub-layer blip the demo injects. Goals
  only ever increment, so replicas reconcile by componentwise max - a
  conflict-free join that converges no matter the message order.

  Replicas gossip their full state on startup and whenever a node joins:
  the newcomer asks peers to push their scores and max-merges the replies,
  then tells the lane's boards to reload so they backfill any rows they missed.
  """
  use GenServer

  alias ScoreBoard.EchoPubSub
  alias ScoreBoard.Lane
  alias ScoreBoard.Match
  alias ScoreBoard.Matches

  require Logger

  @spec start_link(Lane.id()) :: GenServer.on_start()
  def start_link(lane) do
    GenServer.start_link(__MODULE__, lane, name: Lane.db(lane))
  end

  @doc "Whether this lane's replica is running on this node."
  @spec alive?(Lane.id()) :: boolean()
  def alive?(lane), do: is_pid(Process.whereis(Lane.db(lane)))

  @doc "The stored score for a match in `lane`, read from the local replica."
  @spec read(Lane.id(), Matches.match_id()) :: {:ok, Match.score()} | :error
  def read(lane, id), do: safe_call(lane, {:read, id}, :error)

  @doc "Stores the latest score and replicates it to the lane's peer replicas."
  @spec write(Lane.id(), Matches.match_id(), Match.score()) :: :ok | :error
  def write(lane, id, score), do: safe_call(lane, {:write, id, score}, :error)

  @doc "All stored scores for `lane`, keyed by match id, from the local replica."
  @spec all(Lane.id()) :: %{Matches.match_id() => Match.score()}
  def all(lane), do: safe_call(lane, :all, %{})

  @doc """
  Empties this node's replica for `lane`.

  Local only, and deliberately not replicated: a recycled lane is cleared on
  every node in turn (see `ScoreBoard.Lanes`), because max-merge would
  resurrect any row a peer still held.
  """
  @spec clear(Lane.id()) :: :ok | :error
  def clear(lane), do: safe_call(lane, :clear, :error)

  # The lane's replica can be briefly absent - a just-joined node, or one
  # shutting down mid Horde redistribution. Callers (a restarting match) must
  # not crash on that; they get the fallback and retry.
  defp safe_call(lane, request, fallback) do
    GenServer.call(Lane.db(lane), request)
  catch
    :exit, _reason -> fallback
  end

  @impl GenServer
  def init(lane) do
    Logger.warning("DB replica for lane #{inspect(lane)} starting on #{node()}")
    # Future topology changes drive re-sync; existing peers are pulled once
    # in handle_continue below.
    :net_kernel.monitor_nodes(true)
    {:ok, %{lane: lane, scores: %{}}, {:continue, :request_sync}}
  end

  # Ask every already-connected peer to push its scores. A cast, not a call,
  # so two replicas booting at once cannot deadlock waiting on each other.
  @impl GenServer
  def handle_continue(:request_sync, state) do
    for peer <- Node.list(), do: sync_request(state.lane, peer)
    {:noreply, state}
  end

  @impl GenServer
  def handle_call({:read, id}, _from, state) do
    {:reply, Map.fetch(state.scores, id), state}
  end

  def handle_call({:write, id, score}, _from, state) do
    # Peers get the raw value and merge it themselves; abcast excludes us,
    # so we merge our own copy here.
    GenServer.abcast(Node.list(), Lane.db(state.lane), {:replicate, id, score})
    {:reply, :ok, %{state | scores: merge_one(state.scores, id, score)}}
  end

  def handle_call(:all, _from, state) do
    {:reply, state.scores, state}
  end

  def handle_call(:clear, _from, state) do
    {:reply, :ok, %{state | scores: %{}}}
  end

  @impl GenServer
  def handle_cast({:replicate, id, score}, state) do
    {:noreply, %{state | scores: merge_one(state.scores, id, score)}}
  end

  # A peer (re)joined and asked us to send what we have.
  def handle_cast({:sync_request, from}, state) do
    GenServer.cast({Lane.db(state.lane), from}, {:merge_all, state.scores})
    {:noreply, state}
  end

  # A peer's full state arrived; max-merge it and, if it added anything, tell
  # the lane's boards to reload so they backfill the newly learned rows.
  def handle_cast({:merge_all, remote}, state) do
    merged = merge_all(state.scores, remote)

    if merged != state.scores do
      EchoPubSub.broadcast(Lane.pubsub(state.lane), Match.topic(), :db_merged)
    end

    {:noreply, %{state | scores: merged}}
  end

  @impl GenServer
  def handle_info({:nodeup, peer}, state) do
    sync_request(state.lane, peer)
    {:noreply, state}
  end

  def handle_info({:nodedown, _peer}, state), do: {:noreply, state}

  defp sync_request(lane, peer) do
    GenServer.cast({Lane.db(lane), peer}, {:sync_request, node()})
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
