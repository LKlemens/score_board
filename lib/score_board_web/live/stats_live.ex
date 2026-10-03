defmodule ScoreBoardWeb.StatsLive do
  @moduledoc """
  Who is using the demo: visitors, who is online now, and how full the lane
  pool is.

  Counters come from `ScoreBoard.Stats` on this node - the only one serving
  pages - and are polled rather than pushed, which is accurate enough for a
  dashboard and keeps `Stats` free of subscribers. The history strip only
  appears when a `ScoreBoard.Repo` is configured.
  """
  use ScoreBoardWeb, :live_view

  alias ScoreBoard.Lane
  alias ScoreBoard.Stats
  alias ScoreBoard.StatsStore

  @poll_interval 1_000
  @history_points 60

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :poll, @poll_interval)

    {:ok, assign(socket, page_title: "Stats") |> refresh()}
  end

  @impl Phoenix.LiveView
  def handle_info(:poll, socket) do
    Process.send_after(self(), :poll, @poll_interval)
    {:noreply, refresh(socket)}
  end

  defp refresh(socket) do
    assign(socket,
      stats: Stats.snapshot(),
      history: StatsStore.history(@history_points),
      persisted?: StatsStore.enabled?()
    )
  end

  defp percent(_taken, 0), do: 0
  defp percent(taken, total), do: round(taken / total * 100)

  defp stamp(at), do: Calendar.strftime(at, "%H:%M")

  attr :key, :string, required: true, doc: "stat name, also the test handle"
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :hint, :string, default: nil
  attr :tone, :string, default: "text-base-content"

  defp tile(assigns) do
    ~H"""
    <div class="rounded-box border border-base-300 bg-base-100 px-4 py-3 shadow-sm">
      <p class="text-[11px] uppercase tracking-wider opacity-60">{@label}</p>
      <p class={["text-3xl font-bold tabular-nums", @tone]} data-stat={@key}>{@value}</p>
      <p :if={@hint} class="text-xs opacity-60">{@hint}</p>
    </div>
    """
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-6">
        <div class="text-center space-y-1">
          <h1 class="text-2xl font-bold">Demo stats</h1>
          <p class="text-sm opacity-70 font-mono">{node()}</p>
        </div>

        <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
          <.tile
            key="online"
            label="Online now"
            value={to_string(@stats.online)}
            hint="open scoreboards"
          />
          <.tile
            key="visits"
            label="Visits"
            value={to_string(@stats.visits)}
            hint="since first boot"
          />
          <.tile
            key="peak"
            label="Peak online"
            value={to_string(@stats.peak_online)}
            hint="this run"
          />
          <.tile
            key="rejected"
            label="Turned away"
            value={to_string(@stats.rejected)}
            hint="pool was full"
            tone={if @stats.rejected > 0, do: "text-error", else: "text-base-content"}
          />
        </div>

        <div class="rounded-box border border-base-300 bg-base-100 px-4 py-3 shadow-sm space-y-2">
          <div class="flex items-baseline justify-between">
            <p class="text-[11px] uppercase tracking-wider opacity-60">Lane pool</p>
            <p class="text-sm font-mono">
              {@stats.lanes.taken} / {@stats.lanes.total} taken
              <span class="opacity-60">({@stats.lanes.free} free)</span>
            </p>
          </div>
          <div class="h-3 w-full rounded-full bg-base-300 overflow-hidden">
            <div
              class={[
                "h-full transition-all",
                if(@stats.lanes.free == 0, do: "bg-error", else: "bg-success")
              ]}
              style={"width: #{percent(@stats.lanes.taken, @stats.lanes.total)}%"}
            />
          </div>
          <p class="text-xs opacity-60">
            A lane idle for {div(Lane.ttl_ms(), 1_000)}s goes back to the pool.
          </p>
        </div>

        <div
          :if={@persisted? and @history != []}
          class="rounded-box border border-base-300 bg-base-100 px-4 py-3 shadow-sm"
        >
          <p class="text-[11px] uppercase tracking-wider opacity-60 mb-2">History</p>
          <div class="overflow-x-auto">
            <table class="table table-sm whitespace-nowrap">
              <thead>
                <tr>
                  <th class="text-[11px] uppercase opacity-60">Time</th>
                  <th class="text-[11px] uppercase opacity-60 text-right">Online</th>
                  <th class="text-[11px] uppercase opacity-60 text-right">Visits</th>
                  <th class="text-[11px] uppercase opacity-60 text-right">Lanes</th>
                  <th class="text-[11px] uppercase opacity-60 text-right">Turned away</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={sample <- Enum.reverse(@history)} data-sample-id={sample.id}>
                  <td class="font-mono">{stamp(sample.inserted_at)}</td>
                  <td class="text-right tabular-nums">{sample.online}</td>
                  <td class="text-right tabular-nums">{sample.visits}</td>
                  <td class="text-right tabular-nums">
                    {sample.lanes_taken}/{sample.lanes_total}
                  </td>
                  <td class="text-right tabular-nums">{sample.rejected}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <p :if={!@persisted?} data-no-history class="text-center text-xs opacity-50">
          No database configured - counters reset on restart.
        </p>
      </div>
    </Layouts.app>
    """
  end
end
