defmodule ScoreBoard.Stats do
  @moduledoc """
  Counts who is using the demo: visits, who is online right now, and how many
  visitors the lane pool had to turn away.

  "Online" is exact rather than sampled - each connected LiveView registers
  itself and is monitored, so a closed tab drops the count on `:DOWN`. Counts
  live in this process, so they are per node; only the web node serves pages,
  so that is the whole picture. When a `ScoreBoard.Repo` is configured the
  totals are seeded from the last persisted sample and a new sample is written
  every `sample_ms/0`, which is what survives a restart.
  """
  use GenServer

  alias ScoreBoard.Lanes
  alias ScoreBoard.StatsStore
  alias ScoreBoard.Telegram

  @type snapshot :: %{
          visits: non_neg_integer(),
          online: non_neg_integer(),
          peak_online: non_neg_integer(),
          rejected: non_neg_integer(),
          lanes: %{total: non_neg_integer(), taken: non_neg_integer(), free: non_neg_integer()}
        }

  # Hold-off between "pool is full" alerts, so a busy minute sends one message.
  @alert_every_ms :timer.minutes(5)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Records a visitor and counts them as online until their process dies."
  @spec visit(pid()) :: :ok
  def visit(pid \\ self()), do: GenServer.cast(__MODULE__, {:visit, pid})

  @doc "Records a visitor who found the pool full."
  @spec rejected() :: :ok
  def rejected, do: GenServer.cast(__MODULE__, :rejected)

  @doc "Everything the dashboard shows."
  @spec snapshot() :: snapshot()
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  @doc "How often a sample is persisted, when a repo is configured."
  @spec sample_ms() :: pos_integer()
  def sample_ms, do: Application.get_env(:score_board, :stats_sample_ms, :timer.minutes(1))

  @impl GenServer
  def init(:ok) do
    seed = StatsStore.last_totals()
    schedule_sample()

    {:ok,
     %{
       visits: seed.visits,
       rejected: seed.rejected,
       peak_online: 0,
       online: %{},
       alerted_at: nil
     }}
  end

  @impl GenServer
  def handle_cast({:visit, pid}, state) do
    if Map.has_key?(state.online, pid) do
      {:noreply, state}
    else
      ref = Process.monitor(pid)
      online = Map.put(state.online, pid, ref)

      {:noreply,
       %{
         state
         | visits: state.visits + 1,
           online: online,
           peak_online: max(state.peak_online, map_size(online))
       }}
    end
  end

  @impl GenServer
  def handle_cast(:rejected, state) do
    {:noreply, %{state | rejected: state.rejected + 1} |> alert()}
  end

  @impl GenServer
  def handle_call(:snapshot, _from, state) do
    {:reply, build_snapshot(state), state}
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | online: Map.delete(state.online, pid)}}
  end

  @impl GenServer
  def handle_info(:sample, state) do
    schedule_sample()
    StatsStore.record(build_snapshot(state))
    {:noreply, state}
  end

  defp build_snapshot(state) do
    %{
      visits: state.visits,
      online: map_size(state.online),
      peak_online: state.peak_online,
      rejected: state.rejected,
      lanes: Lanes.stats()
    }
  end

  defp schedule_sample, do: Process.send_after(self(), :sample, sample_ms())

  # A full pool is the one thing worth a phone buzz, but only now and then.
  defp alert(state) do
    now = System.monotonic_time(:millisecond)

    if state.alerted_at == nil or now - state.alerted_at >= @alert_every_ms do
      lanes = Lanes.stats()

      Telegram.notify(
        "Scoreboard pool full: #{lanes.taken}/#{lanes.total} lanes taken, " <>
          "#{state.rejected} visitors turned away."
      )

      %{state | alerted_at: now}
    else
      state
    end
  end
end
