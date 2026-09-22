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
  alias ScoreBoard.Lanes
  alias ScoreBoard.Matches
  alias ScoreBoardWeb.ClusterViz

  @poll_interval 500
  @remote_timeout 500

  @impl Phoenix.LiveView
  def mount(_params, session, socket) do
    tenant = session["tenant"] || "anon-#{:erlang.phash2(self())}"

    case Lanes.assign(tenant) do
      {:ok, lane} ->
        if connected?(socket) do
          # Local board changes re-render instantly; remote boards are polled,
          # and node up/down reshapes the columns.
          Board.subscribe(lane)
          :net_kernel.monitor_nodes(true)
          Process.send_after(self(), :poll, @poll_interval)
        end

        socket =
          assign(socket,
            page_title: "Scoreboard",
            node: node(),
            lane: lane,
            error: nil,
            blip: Blip.enabled?(lane)
          )

        {:ok, refresh(socket)}

      {:error, :pool_exhausted} ->
        socket =
          assign(socket,
            page_title: "Scoreboard",
            node: node(),
            lane: nil,
            error: "All demo lanes are busy right now - try again in a moment.",
            blip: false,
            nodes: [],
            cluster: %{},
            boards: %{},
            matches: []
          )

        {:ok, socket}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("goal", %{"id" => id, "team" => team}, socket) do
    case score_goal_healing(socket.assigns.lane, id, team_atom(team)) do
      :ok -> {:noreply, socket |> assign(error: nil) |> push_goal_flight(id, team)}
      {:error, :match_not_found} -> {:noreply, assign(socket, error: "Match #{id} is gone.")}
    end
  end

  def handle_event("toggle-node", %{"node" => node_str}, socket) do
    lane = socket.assigns.lane
    target = String.to_existing_atom(node_str)
    toggle_blip(lane, target)
    # Keep the header badge in step when this node was toggled.
    socket = if target == node(), do: assign(socket, blip: Blip.enabled?(lane)), else: socket
    {:noreply, refresh(socket)}
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

  # A board row can outlive its match process (a failover mid-move, a crash).
  # The score is still in the DB, so recreate the match - it restores from the
  # DB - and retry once, instead of failing the click.
  defp score_goal_healing(lane, id, team) do
    case Matches.score_goal(lane, id, team) do
      :ok ->
        :ok

      {:error, :match_not_found} ->
        Matches.create_match(lane, id)
        Matches.score_goal(lane, id, team)
    end
  end

  # Tell the browser to fly the goal along the path it really takes: this
  # node hands it to the match owner, the owner broadcasts it out. Hops
  # over a link that is down are left out, so a goal visibly stops at a
  # node that has gone offline.
  defp push_goal_flight(socket, id, team) do
    case owner(socket.assigns.lane, id) do
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

  defp refresh(%{assigns: %{lane: nil}} = socket), do: socket

  defp refresh(socket) do
    lane = socket.assigns.lane
    nodes = Enum.sort([node() | Node.list()])
    cluster = Map.new(nodes, &{&1, snapshot_on(lane, &1)})

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
      |> Enum.map(fn id ->
        %{id: id, owner: owner(lane, id), true_score: true_score(lane, id)}
      end)

    socket
    |> push_flush(cluster)
    |> assign(nodes: nodes, cluster: cluster, boards: boards, matches: matches)
  end

  defp toggle_blip(lane, target) when target == node() do
    if Blip.enabled?(lane) do
      Blip.off(lane)
      # Coming back online: catch the frozen board up to the truth at once.
      Board.reload(lane)
    else
      Blip.on(lane)
    end
  end

  defp toggle_blip(lane, target) do
    if :erpc.call(target, Blip, :enabled?, [lane], @remote_timeout) do
      :erpc.call(target, Blip, :off, [lane], @remote_timeout)
      :erpc.call(target, Board, :reload, [lane], @remote_timeout)
    else
      :erpc.call(target, Blip, :on, [lane], @remote_timeout)
    end
  catch
    # A node can vanish between listing and toggling.
    _kind, _reason -> :ok
  end

  defp snapshot_on(lane, board_node) when board_node == node(), do: Cluster.snapshot(lane)

  defp snapshot_on(lane, board_node) do
    :erpc.call(board_node, Cluster, :snapshot, [lane], @remote_timeout)
  catch
    # A node can vanish between listing and reading.
    _kind, _reason -> :unreachable
  end

  defp owner(lane, id) do
    case Matches.owner_node(lane, id) do
      {:ok, owner} -> owner
      {:error, :match_not_found} -> nil
    end
  end

  defp true_score(lane, id) do
    case Matches.score(lane, id) do
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

        <ClusterViz.cluster_viz nodes={@nodes} cluster={@cluster} node={@node} />

        <div
          :if={@error}
          role="alert"
          class="alert alert-error max-w-xl mx-auto shadow-lg text-base font-semibold"
        >
          <span class="text-xl">⚠</span>
          <span>{@error}</span>
        </div>

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
                <th :for={board_node <- @nodes} class="text-center">
                  <div class="flex flex-col items-center gap-1">
                    <span class="font-mono text-xs">{short_name(board_node)}</span>
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
                  <span class="badge badge-ghost badge-sm font-mono">
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
      </div>
    </Layouts.app>
    """
  end
end
