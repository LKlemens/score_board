defmodule ScoreBoard.Stats do
  @moduledoc """
  Counts who is using the demo: visitors, who is online right now, and how many
  visitors the lane pool had to turn away.

  Both visitor numbers are keyed on the tenant cookie, not on the LiveView
  process, so a refresh or a second tab is still one browser. "Online" is
  exact rather than sampled - each connected LiveView is monitored, so a closed
  tab drops out on `:DOWN` and the person disappears once their last tab is
  gone. Counts live in this process, so they are per node; only the web node
  serves pages, so that is the whole picture. When a `ScoreBoard.Repo` is
  configured the totals are seeded from the last persisted sample, which is what
  survives a restart.

  Only the node that serves pages persists or reports: the headless boards run
  an idle copy of this server, and without that guard all three would write the
  same minute's row and send the same daily digest. A sample is written only
  when the numbers actually moved, so an idle demo writes nothing and the
  history reads as a list of changes.
  """
  use GenServer

  alias ScoreBoard.Lanes
  alias ScoreBoard.StatsDigest
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

  @doc """
  Records a visitor and counts them as online until their process dies.

  `tenant` is the browser's cookie, so reloading or opening a second tab adds
  a process to an existing visitor rather than a new one.
  """
  @spec visit(Lanes.tenant(), pid()) :: :ok
  def visit(tenant, pid \\ self()), do: GenServer.cast(__MODULE__, {:visit, tenant, pid})

  @doc "Records a visitor who found the pool full."
  @spec rejected() :: :ok
  def rejected, do: GenServer.cast(__MODULE__, :rejected)

  @doc "Everything the dashboard shows."
  @spec snapshot() :: snapshot()
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  @doc "How often the counters are checked for a sample or a digest."
  @spec sample_ms() :: pos_integer()
  def sample_ms, do: Application.get_env(:score_board, :stats_sample_ms, :timer.minutes(1))

  @doc "The UTC hour the daily digest goes out."
  @spec digest_hour() :: 0..23
  def digest_hour, do: Application.get_env(:score_board, :digest_hour_utc, 8)

  @doc """
  Whether this node serves pages, and so owns persistence and reporting.

  The headless boards of a release run the same supervision tree; only the one
  started with `PHX_SERVER=true` has the endpoint listening. Phoenix's own check
  is used because `mix phx.server` enables the endpoint through
  `:phoenix, :serve_endpoints` rather than the endpoint's `:server` key.
  """
  @spec serving?() :: boolean()
  def serving?, do: Phoenix.Endpoint.server?(:score_board, ScoreBoardWeb.Endpoint)

  @doc false
  @spec digest_due?(StatsDigest.t() | nil, DateTime.t(), 0..23) :: boolean()
  def digest_due?(last_digest, now, hour) do
    now.hour >= hour and (last_digest == nil or Date.compare(last_digest.sent_on, now) == :lt)
  end

  @doc false
  @spec digest_changed?(StatsDigest.t() | nil, snapshot()) :: boolean()
  def digest_changed?(nil, snapshot), do: snapshot.visits > 0 or snapshot.rejected > 0

  def digest_changed?(last_digest, snapshot) do
    last_digest.visits != snapshot.visits or last_digest.rejected != snapshot.rejected or
      last_digest.peak_online != snapshot.peak_online
  end

  @impl GenServer
  def init(:ok) do
    seed = if serving?(), do: StatsStore.last_totals(), else: %{visits: 0, rejected: 0}
    if serving?(), do: schedule_sample()

    {:ok,
     %{
       visits: seed.visits,
       rejected: seed.rejected,
       peak_online: 0,
       # pid => tenant, so several tabs of one browser are one visitor.
       online: %{},
       seen: MapSet.new(),
       alerted_at: nil,
       # The last snapshot written, so an unchanged minute writes nothing.
       last_sample: nil
     }}
  end

  @impl GenServer
  def handle_cast({:visit, tenant, pid}, state) do
    if Map.has_key?(state.online, pid) do
      {:noreply, state}
    else
      Process.monitor(pid)
      online = Map.put(state.online, pid, tenant)
      first_visit? = not MapSet.member?(state.seen, tenant)

      {:noreply,
       %{
         state
         | visits: state.visits + if(first_visit?, do: 1, else: 0),
           seen: MapSet.put(state.seen, tenant),
           online: online,
           peak_online: max(state.peak_online, count_online(online))
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
    snapshot = build_snapshot(state)

    {:noreply, state |> record_sample(snapshot) |> maybe_digest(snapshot)}
  end

  defp record_sample(state, snapshot) do
    if snapshot == state.last_sample do
      state
    else
      StatsStore.record(snapshot)
      %{state | last_sample: snapshot}
    end
  end

  # Once a day, past the configured hour: report the day's movement, or record
  # the day as handled and stay quiet when nothing moved.
  defp maybe_digest(state, snapshot) do
    last = StatsStore.last_digest()
    now = DateTime.utc_now()

    if digest_due?(last, now, digest_hour()) do
      changed? = digest_changed?(last, snapshot)
      if changed?, do: Telegram.notify(digest_message(last, snapshot))
      StatsStore.record_digest(snapshot, DateTime.to_date(now), changed?)
    end

    state
  end

  defp digest_message(last, snapshot) do
    since = fn field -> snapshot[field] - ((last && Map.get(last, field)) || 0) end

    """
    Scoreboard daily summary
    New visitors: #{since.(:visits)} (#{snapshot.visits} total)
    Turned away: #{since.(:rejected)} (#{snapshot.rejected} total)
    Peak online: #{snapshot.peak_online}
    Lanes in use: #{snapshot.lanes.taken}/#{snapshot.lanes.total}
    """
  end

  defp build_snapshot(state) do
    %{
      visits: state.visits,
      online: count_online(state.online),
      peak_online: state.peak_online,
      rejected: state.rejected,
      lanes: Lanes.stats()
    }
  end

  defp count_online(online), do: online |> Map.values() |> Enum.uniq() |> length()

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
