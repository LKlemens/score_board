defmodule ScoreBoardWeb.ScoreLive do
  @moduledoc """
  Cluster-wide scoreboard: every node's derived board side by side.

  Score a goal anywhere and watch all boards converge; a node that missed
  events shows a red, lagging cell next to the true score. Remote boards
  are read over `:erpc` - distribution, not PubSub - so the observation
  channel stays reliable even when the PubSub layer is degraded: stale
  boards cannot be demonstrated through the same channel that drops the
  data.
  """
  use ScoreBoardWeb, :live_view

  alias ScoreBoard.Blip
  alias ScoreBoard.Board
  alias ScoreBoard.Cluster
  alias ScoreBoard.Matches
  alias ScoreBoardWeb.ClusterViz
  alias ScoreBoardWeb.ProcessViz

  @poll_interval 500
  @remote_timeout 500

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Local board changes re-render instantly; remote boards are polled,
      # and node up/down reshapes the columns.
      Board.subscribe()
      :net_kernel.monitor_nodes(true)
      Process.send_after(self(), :poll, @poll_interval)
    end

    socket =
      assign(socket,
        page_title: "Scoreboard",
        node: node(),
        error: nil,
        blip: Blip.enabled?(),
        show_processes?: false,
        buffer_since: %{},
        sustained: MapSet.new()
      )

    {:ok, refresh(socket)}
  end

  @impl Phoenix.LiveView
  def handle_event("goal", %{"id" => id, "team" => team}, socket) do
    case Matches.score_goal(id, team_atom(team)) do
      :ok -> {:noreply, socket |> assign(error: nil) |> push_goal_flight(id, team)}
      {:error, :match_not_found} -> {:noreply, assign(socket, error: "match #{id} is gone")}
    end
  end

  def handle_event("toggle-node", %{"node" => node_str}, socket) do
    target = String.to_existing_atom(node_str)
    toggle_blip(target)
    # Keep the header badge in step when this node was toggled.
    socket = if target == node(), do: assign(socket, blip: Blip.enabled?()), else: socket
    {:noreply, refresh(socket)}
  end

  def handle_event("toggle-processes", _params, socket) do
    {:noreply, update(socket, :show_processes?, &(not &1))}
  end

  @impl Phoenix.LiveView
  def handle_info(:poll, socket) do
    Process.send_after(self(), :poll, @poll_interval)
    {:noreply, refresh(socket)}
  end

  def handle_info({:nodeup, _node}, socket), do: {:noreply, refresh(socket)}
  def handle_info({:nodedown, _node}, socket), do: {:noreply, refresh(socket)}
  def handle_info({:match_added, _id}, socket), do: {:noreply, refresh(socket)}
  def handle_info({:match_removed, _id}, socket), do: {:noreply, refresh(socket)}
  def handle_info({:score_updated, _id, _score}, socket), do: {:noreply, refresh(socket)}
  def handle_info(:board_reloaded, socket), do: {:noreply, refresh(socket)}

  defp team_atom("home"), do: :home
  defp team_atom("away"), do: :away

  # Tell the browser to fly the goal along the path it really takes: this
  # node hands it to the match owner, the owner broadcasts it out. Hops
  # over a link that is down are left out, so a goal visibly stops at a
  # node that has gone offline.
  defp push_goal_flight(socket, id, team) do
    case owner(id) do
      nil -> socket
      owner -> push_event(socket, "goal-flight", %{team: team, hops: hops(socket, owner)})
    end
  end

  defp hops(socket, owner) do
    %{nodes: nodes, cluster: cluster} = socket.assigns
    ClusterViz.goal_hops(cluster, nodes, owner)
  end

  # A node that was offline flushes everything it buffered - and everything
  # buffered towards it - the moment it is back. The previous snapshot is
  # the only place those counts still exist, so the comparison has to
  # happen here, before the new one replaces it.
  defp push_flush(socket, cluster) do
    case Map.get(socket.assigns, :cluster) do
      nil ->
        socket

      was ->
        case ClusterViz.flush_streams(was, cluster) do
          [] -> socket
          streams -> push_event(socket, "cluster-flush", %{streams: streams})
        end
    end
  end

  defp refresh(socket) do
    nodes = Enum.sort([node() | Node.list()])
    cluster = Map.new(nodes, &{&1, snapshot_on(&1)})

    boards =
      Map.new(cluster, fn
        {board_node, :unreachable} -> {board_node, :unreachable}
        {board_node, snapshot} -> {board_node, snapshot.scores}
      end)

    matches =
      boards
      |> Map.values()
      |> Enum.flat_map(fn
        :unreachable -> []
        scores -> Map.keys(scores)
      end)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(fn id -> %{id: id, owner: owner(id), true_score: true_score(id)} end)

    # A backlog only earns a box once it has been held a while, so normal
    # in-flight traffic between healthy nodes does not draw one.
    {sustained, since} =
      ClusterViz.sustained(
        cluster,
        socket.assigns.buffer_since,
        System.monotonic_time(:millisecond)
      )

    socket
    |> push_flush(cluster)
    |> assign(
      nodes: nodes,
      cluster: cluster,
      boards: boards,
      matches: matches,
      buffer_since: since,
      sustained: sustained
    )
  end

  defp toggle_blip(target) when target == node() do
    if Blip.enabled?(), do: Blip.off(), else: Blip.on()
  end

  defp toggle_blip(target) do
    if :erpc.call(target, Blip, :enabled?, [], @remote_timeout) do
      :erpc.call(target, Blip, :off, [], @remote_timeout)
    else
      :erpc.call(target, Blip, :on, [], @remote_timeout)
    end
  catch
    # A node can vanish between listing and toggling.
    _kind, _reason -> :ok
  end

  defp snapshot_on(board_node) when board_node == node(), do: Cluster.snapshot()

  defp snapshot_on(board_node) do
    :erpc.call(board_node, Cluster, :snapshot, [], @remote_timeout)
  catch
    # A node can vanish between listing and reading.
    _kind, _reason -> :unreachable
  end

  defp owner(id) do
    case Matches.owner_node(id) do
      {:ok, owner} -> owner
      {:error, :match_not_found} -> nil
    end
  end

  defp true_score(id) do
    case Matches.score(id) do
      {:ok, score} -> score
      {:error, :match_not_found} -> nil
    end
  end

  defp cell(boards, board_node, id) do
    case boards[board_node] do
      :unreachable -> nil
      scores -> scores[id]
    end
  end

  # A cell is stale when the truth is known and this board disagrees -
  # including a missing row (the board never saw the match).
  defp stale?(_cell, nil), do: false
  defp stale?(cell, truth), do: cell != truth

  # The three ideas the picture below illustrates, in the order they happen.
  defp steps do
    [
      %{
        number: "1",
        title: "One process per match",
        body:
          "Each match is a single process living on one node of the cluster - the only " <>
            "place its score can be updated."
      },
      %{
        number: "2",
        title: "Each node reads locally",
        body:
          "Every node runs a board process keeping each match's score in an ETS table, so a " <>
            "read is a local lookup. Without it every read would be a GenServer.call to the " <>
            "match process, and a hot match would become a bottleneck."
      },
      %{
        number: "3",
        title: "Broadcasts keep them equal",
        body:
          "When a goal is scored, the match process broadcasts it. Every board listens for " <>
            "those events and writes them to its own ETS table, so all nodes end up with the " <>
            "same score without ever asking the match."
      }
    ]
  end

  defp short_name(node_atom) do
    node_atom |> Atom.to_string() |> String.split("@") |> hd()
  end

  attr :score, :map, default: nil, doc: "a %{home: _, away: _} score, or nil"
  attr :stale?, :boolean, default: false, doc: "this board disagrees with the truth"
  attr :truth?, :boolean, default: false, doc: "render as the authoritative score"

  defp score(assigns) do
    ~H"""
    <span :if={@score == nil} class="opacity-40">-</span>
    <span
      :if={@score}
      class={[
        "font-mono tabular-nums font-semibold",
        @truth? && "text-lg font-bold",
        @stale? && "badge badge-error badge-lg gap-0 font-bold animate-pulse",
        !@stale? && !@truth? && "text-base"
      ]}
    >
      {@score.home}<span class="opacity-50">{" : "}</span>{@score.away}
    </span>
    """
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-8">
        <div class="text-center space-y-2">
          <h1 class="text-2xl font-bold">Live Scoreboard</h1>
          <p class="text-sm opacity-70 font-mono">{@node}</p>
          <span id="net-status" class={["badge", (@blip && "badge-error") || "badge-success"]}>
            {if @blip, do: "offline", else: "connected"}
          </span>
        </div>

        <ClusterViz.cluster_viz
          nodes={@nodes}
          cluster={@cluster}
          node={@node}
          sustained={@sustained}
        />

        <p :if={@error} class="text-error text-center text-sm">{@error}</p>

        <p :if={@matches != []} class="text-center text-xs opacity-60 -mb-4">
          one column per node - each is a separate BEAM VM keeping its own derived board,
          next to the true score held by the match process
        </p>

        <div
          :if={@matches != []}
          class="overflow-x-auto rounded-box border border-base-300 bg-base-100 shadow-sm"
        >
          <table class="table table-zebra whitespace-nowrap">
            <thead>
              <tr class="bg-base-200">
                <th class="text-[11px] uppercase tracking-wider opacity-70">Match</th>
                <th class="text-[11px] uppercase tracking-wider opacity-70">Owner</th>
                <th class="text-center text-[11px] uppercase tracking-wider opacity-70">
                  True score
                </th>
                <th :for={board_node <- @nodes} class="text-center" title={board_node}>
                  <div class="flex flex-col items-center gap-1">
                    <span class="font-mono text-xs cursor-help">{short_name(board_node)}</span>
                    <span :if={board_node == @node} class="badge badge-ghost badge-xs">this</span>
                    <span
                      :if={@boards[board_node] == :unreachable}
                      class="badge badge-error badge-xs"
                    >
                      offline
                    </span>
                  </div>
                </th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={match <- @matches} data-match-id={match.id} class="hover:bg-base-200/60">
                <td class="font-mono font-medium">{match.id}</td>
                <td>
                  <span class="badge badge-ghost badge-sm font-mono cursor-help" title={match.owner}>
                    {(match.owner && short_name(match.owner)) || "…"}
                  </span>
                </td>
                <td class="text-center" data-true-score-id={match.id}>
                  <.score score={match.true_score} truth?={true} />
                </td>
                <td
                  :for={board_node <- @nodes}
                  class="text-center"
                  data-score-id={match.id}
                  data-node={board_node}
                >
                  <.score
                    score={cell(@boards, board_node, match.id)}
                    stale?={stale?(cell(@boards, board_node, match.id), match.true_score)}
                  />
                </td>
                <td class="text-right">
                  <div class="join">
                    <button
                      class="btn btn-sm btn-primary join-item"
                      phx-click="goal"
                      phx-value-id={match.id}
                      phx-value-team="home"
                    >
                      Goal Home
                    </button>
                    <button
                      class="btn btn-sm btn-warning join-item"
                      phx-click="goal"
                      phx-value-id={match.id}
                      phx-value-team="away"
                    >
                      Goal Away
                    </button>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <p :if={@matches == []} class="text-center opacity-70">
          No matches yet.
        </p>

        <section
          class="max-w-4xl mx-auto rounded-box border border-base-300 bg-base-200/30 shadow-sm"
          data-intro
        >
          <button
            class="w-full flex items-center justify-between gap-3 px-5 py-3 cursor-pointer hover:bg-base-200/60 rounded-box transition-colors"
            phx-click="toggle-processes"
          >
            <span class="text-sm font-bold uppercase tracking-wider opacity-70">
              What runs behind this board
            </span>
            <span class="btn btn-xs btn-ghost gap-1 pointer-events-none">
              {if @show_processes?, do: "Hide", else: "Show"}
              <span aria-hidden="true">{if @show_processes?, do: "▾", else: "▸"}</span>
            </span>
          </button>

          <div :if={@show_processes?} class="px-5 pb-5 space-y-5">
            <div class="grid gap-3 sm:grid-cols-3">
              <article
                :for={step <- steps()}
                class="rounded-box border border-base-300 bg-base-100 p-4 space-y-2"
              >
                <div class="flex items-center gap-2">
                  <span class="badge badge-primary badge-sm font-bold">{step.number}</span>
                  <h3 class="text-sm font-semibold">{step.title}</h3>
                </div>
                <p class="text-xs leading-relaxed opacity-80">{step.body}</p>
              </article>
            </div>

            <ProcessViz.process_map
              nodes={@nodes}
              matches={@matches}
              boards={@boards}
              node={@node}
            />

            <div class="rounded-box border border-base-300 bg-base-100 px-4 py-3">
              <ProcessViz.legend />
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
