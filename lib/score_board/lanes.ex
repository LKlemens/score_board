defmodule ScoreBoard.Lanes do
  @moduledoc """
  Assigns a free lane to a tenant and hands it back when idle.

  The lanes themselves are pre-started by `ScoreBoard.LanePool`; this server
  only tracks which are free and which tenant holds which. `assign/1` is
  idempotent - a tenant that already holds a lane gets the same one back - so a
  reconnecting browser resumes its state. When the pool is empty `assign/1`
  returns `{:error, :pool_exhausted}` and the caller shows a "come back later"
  page.
  """
  use GenServer

  alias ScoreBoard.Lane

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

  @impl GenServer
  def init(:ok), do: {:ok, %{free: Lane.ids(), taken: %{}}}

  @impl GenServer
  def handle_call({:assign, tenant}, _from, state) do
    case Map.fetch(state.taken, tenant) do
      {:ok, id} ->
        {:reply, {:ok, id}, state}

      :error ->
        case state.free do
          [] ->
            {:reply, {:error, :pool_exhausted}, state}

          [id | rest] ->
            {:reply, {:ok, id}, %{state | free: rest, taken: Map.put(state.taken, tenant, id)}}
        end
    end
  end

  @impl GenServer
  def handle_call({:release, tenant}, _from, state) do
    case Map.pop(state.taken, tenant) do
      {nil, _taken} -> {:reply, :ok, state}
      {id, taken} -> {:reply, :ok, %{state | free: [id | state.free], taken: taken}}
    end
  end

  @impl GenServer
  def handle_call({:lane_for, tenant}, _from, state) do
    {:reply, Map.fetch(state.taken, tenant), state}
  end
end
