defmodule ScoreBoard.Lanes do
  @moduledoc """
  Assigns a free lane to a tenant and hands it back when idle.

  The lanes themselves are pre-started by `ScoreBoard.LanePool`; this server
  only tracks which are free and which tenant holds which. `assign/1` is
  idempotent - a tenant that already holds a lane gets the same one back - so a
  reconnecting browser resumes its state. When the pool is empty `assign/1`
  returns `{:error, :pool_exhausted}` and the caller shows a "come back later"
  page.

  A lane is only reclaimed on `release/1` or by the idle sweeper: every
  `Lane.sweep_ms/0` a tenant untouched for `Lane.ttl_ms/0` loses its lane, so a
  browser that was left open does not hold a lane forever. The lane is wiped
  before it goes back to the pool and the tenant is told on
  `"lane:<tenant>"` so its page can say the session was dropped.
  """
  use GenServer

  alias ScoreBoard.Board
  alias ScoreBoard.DB
  alias ScoreBoard.Lane
  alias ScoreBoard.Matches

  @type tenant :: String.t()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Gives `tenant` its lane, assigning a free one on first call."
  @spec assign(tenant()) :: {:ok, Lane.id()} | {:error, :pool_exhausted}
  def assign(tenant), do: GenServer.call(__MODULE__, {:assign, tenant})

  @doc "Returns `tenant`'s lane to the pool."
  @spec release(tenant()) :: :ok
  def release(tenant), do: GenServer.call(__MODULE__, {:release, tenant})

  @doc "The lane a tenant currently holds, if any."
  @spec lane_for(tenant()) :: {:ok, Lane.id()} | :error
  def lane_for(tenant), do: GenServer.call(__MODULE__, {:lane_for, tenant})

  @doc "Marks `tenant` as active, restarting its idle clock."
  @spec touch(tenant()) :: :ok
  def touch(tenant), do: GenServer.cast(__MODULE__, {:touch, tenant})

  @doc "Reclaims every lane idle past the TTL. Runs on a timer; exposed for tests."
  @spec sweep() :: [tenant()]
  def sweep, do: GenServer.call(__MODULE__, :sweep)

  @doc "How much of the pool is in use right now."
  @spec stats() :: %{total: non_neg_integer(), taken: non_neg_integer(), free: non_neg_integer()}
  def stats, do: GenServer.call(__MODULE__, :stats)

  @doc "The PubSub topic a tenant hears about its own lane on."
  @spec topic(tenant()) :: String.t()
  def topic(tenant), do: "lane:#{tenant}"

  @impl GenServer
  def init(:ok) do
    # A node joining/leaving reshapes how many markets each active lane needs.
    :net_kernel.monitor_nodes(true)
    schedule_sweep()
    {:ok, %{free: Lane.ids(), taken: %{}, seen: %{}}}
  end

  @impl GenServer
  def handle_call({:assign, tenant}, _from, state) do
    case Map.fetch(state.taken, tenant) do
      {:ok, id} ->
        {:reply, {:ok, id}, touched(state, tenant)}

      :error ->
        case state.free do
          [] ->
            {:reply, {:error, :pool_exhausted}, state}

          [id | rest] ->
            # Seed the lane's markets now - at runtime the cluster is connected
            # (BootBarrier settled Horde at boot), so RoundRobin places one per node.
            Matches.ensure_markets(id)

            state = %{state | free: rest, taken: Map.put(state.taken, tenant, id)}
            {:reply, {:ok, id}, touched(state, tenant)}
        end
    end
  end

  @impl GenServer
  def handle_call({:release, tenant}, _from, state) do
    {:reply, :ok, reclaim(state, tenant)}
  end

  @impl GenServer
  def handle_call({:lane_for, tenant}, _from, state) do
    {:reply, Map.fetch(state.taken, tenant), state}
  end

  @impl GenServer
  def handle_call(:stats, _from, state) do
    taken = map_size(state.taken)
    {:reply, %{total: taken + length(state.free), taken: taken, free: length(state.free)}, state}
  end

  @impl GenServer
  def handle_call(:sweep, _from, state) do
    idle = idle_tenants(state)
    {:reply, idle, Enum.reduce(idle, state, &evict(&2, &1))}
  end

  @impl GenServer
  def handle_cast({:touch, tenant}, state) do
    {:noreply, touched(state, tenant)}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    schedule_sweep()
    idle = idle_tenants(state)
    {:noreply, Enum.reduce(idle, state, &evict(&2, &1))}
  end

  # Node count changed: top up every active lane so markets track node count.
  # Only the web node holds taken lanes, so elsewhere this is a no-op.
  def handle_info({node_event, _node}, state) when node_event in [:nodeup, :nodedown] do
    for {_tenant, lane} <- state.taken, do: Matches.ensure_markets(lane)
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, Lane.sweep_ms())

  defp touched(state, tenant) do
    if Map.has_key?(state.taken, tenant) do
      %{state | seen: Map.put(state.seen, tenant, now())}
    else
      state
    end
  end

  defp idle_tenants(state) do
    cutoff = now() - Lane.ttl_ms()

    for {tenant, _id} <- state.taken, Map.get(state.seen, tenant, 0) <= cutoff, do: tenant
  end

  # The tenant's page hears about this and stops; the lane is wiped so whoever
  # picks it up next does not inherit the previous scores.
  defp evict(state, tenant) do
    with {:ok, id} <- Map.fetch(state.taken, tenant) do
      wipe(id)
      Phoenix.PubSub.broadcast(ScoreBoard.PubSub, topic(tenant), :lane_expired)
    end

    reclaim(state, tenant)
  end

  defp reclaim(state, tenant) do
    case Map.pop(state.taken, tenant) do
      {nil, _taken} ->
        state

      {id, taken} ->
        %{state | free: [id | state.free], taken: taken, seen: Map.delete(state.seen, tenant)}
    end
  end

  # Matches first, then every node's replica: a replica cleared while a match
  # still lived would be refilled by that match's next write, and one cleared
  # while a peer still held rows would get them back by max-merge.
  defp wipe(lane) do
    Matches.stop_markets(lane)

    for board_node <- [node() | Node.list()] do
      clear_on(board_node, lane)
    end

    :ok
  end

  defp clear_on(board_node, lane) when board_node == node() do
    DB.clear(lane)
    Board.reload(lane)
  end

  defp clear_on(board_node, lane) do
    :erpc.call(board_node, DB, :clear, [lane], 1_000)
    :erpc.call(board_node, Board, :reload, [lane], 1_000)
  catch
    # A node can vanish mid-wipe; its replica dies with it.
    _kind, _reason -> :ok
  end

  defp now, do: System.monotonic_time(:millisecond)
end
