defmodule ScoreBoardWeb.ClusterViz do
  @moduledoc """
  Animated SVG of the cluster.

  Nodes are laid out as a regular polygon (triangle for 3, square for 4,
  and so on; one or two nodes sit on a horizontal line). Healthy links
  carry faint traveling message dots; a link to a blipped or unreachable
  node turns red. The box beside a lagging node counts the messages it is
  missing - queued at its peers, flushed once the connection is back; red
  once past the ring buffer, when the node will reload instead of replay.

  A scored goal is drawn on top of this ambient traffic by the `ClusterFx`
  JavaScript hook: it reads the link geometry out of this SVG and flies a
  comet along it. The empty `cluster-fx` group is where those temporary
  elements live; it is marked `phx-update="ignore"` so the half-second
  poll cannot wipe a comet mid-flight. The same hook replays a node's
  buffered backlog as a burst of dots when that node comes back online.
  """
  use Phoenix.Component

  @center_x 360
  @polygon_radius 115
  @polygon_center_y 155
  @line_center_y 70

  # How far a link bows away from the middle of the graph.
  @bow 24

  attr :nodes, :list, required: true, doc: "sorted cluster nodes"
  attr :cluster, :map, required: true, doc: "node => Cluster.snapshot() | :unreachable"
  attr :node, :atom, required: true, doc: "the node serving this page"

  def cluster_viz(assigns) do
    positions = positions(assigns.nodes)

    assigns =
      assigns
      |> assign(:height, svg_height(length(assigns.nodes)))
      |> assign(:links, links(assigns.nodes, positions, assigns.cluster))
      |> assign(:circles, circles(assigns.nodes, positions, assigns.cluster, assigns.node))

    ~H"""
    <svg
      id="cluster-viz"
      phx-hook="ClusterFx"
      viewBox={"0 0 720 #{@height}"}
      class="w-full max-w-3xl mx-auto"
    >
      <defs>
        <radialGradient
          :for={tone <- ~w(success error base-300)}
          id={"node-#{tone}"}
          cx="35%"
          cy="28%"
          r="80%"
        >
          <stop offset="0%" stop-color={"var(--color-#{tone})"} stop-opacity="1" />
          <stop offset="100%" stop-color={"var(--color-#{tone})"} stop-opacity="0.45" />
        </radialGradient>
        <filter id="node-glow" x="-80%" y="-80%" width="260%" height="260%">
          <feGaussianBlur stdDeviation="6" />
        </filter>
      </defs>

      <g :for={link <- @links}>
        <path
          d={link.path}
          class={link.class}
          fill="none"
          stroke-width="2.5"
          stroke-linecap="round"
          data-link-from={link.from}
          data-link-to={link.to}
          data-healthy={to_string(link.healthy?)}
        />
        <g :if={link.healthy?}>
          <circle r="3.5" class="fill-primary opacity-45">
            <animateMotion dur="2.4s" repeatCount="indefinite" path={link.path} />
          </circle>
          <circle r="3.5" class="fill-primary opacity-25">
            <animateMotion
              dur="2.4s"
              begin="-1.2s"
              repeatCount="indefinite"
              calcMode="linear"
              keyPoints="1;0"
              keyTimes="0;1"
              path={link.path}
            />
          </circle>
        </g>
      </g>

      <g :for={circle <- @circles}>
        <circle
          cx={circle.x}
          cy={circle.y}
          r="26"
          class={[circle.halo_class, "opacity-30", circle.pulse? && "animate-pulse"]}
          filter="url(#node-glow)"
        />
        <circle
          cx={circle.x}
          cy={circle.y}
          r="20"
          fill={circle.fill}
          class="stroke-base-100"
          stroke-width="2"
          stroke-opacity="0.7"
          data-node-dot={circle.node}
        />
        <g :if={circle.missing > 0}>
          <rect
            x={circle.badge_x}
            y={circle.y - 12}
            width="38"
            height="24"
            rx="8"
            class={circle.missing_class}
            data-missing-box={circle.node}
          />
          <text
            x={circle.badge_x + 19}
            y={circle.y + 4}
            text-anchor="middle"
            class="fill-base-100 text-[12px] font-bold"
          >
            {circle.missing}
          </text>
          <g class="cursor-help">
            <title>
              {if circle.overflow?,
                do: "missing_msg: #{circle.missing}, capacity: overflow",
                else: "missing_msg: #{circle.missing}, max_capacity: #{circle.capacity || "?"}"} —
              Orange: queued at its peers (up to the max capacity of {circle.capacity || "?"})
              and replayed in order once the connection is back.
              Red: past capacity - the node receives cursor_expired and reloads
              from the match processes instead.
            </title>
            <circle cx={circle.info_x} cy={circle.y} r="9" class="fill-info opacity-80" />
            <text
              x={circle.info_x}
              y={circle.y + 4}
              text-anchor="middle"
              class="fill-base-100 text-[11px] font-bold italic"
            >
              i
            </text>
          </g>
        </g>
        <rect
          x={circle.x - circle.label_width / 2}
          y={circle.y + 28}
          width={circle.label_width}
          height="19"
          rx="9"
          class="fill-base-300 opacity-70"
        />
        <text
          x={circle.x}
          y={circle.y + 41}
          text-anchor="middle"
          class="fill-current text-[12px] font-mono"
        >
          {circle.label}
        </text>
        <g
          :if={circle.reachable?}
          class="cursor-pointer transition-opacity hover:opacity-80"
          phx-click="toggle-node"
          phx-value-node={circle.node}
        >
          <rect
            x={circle.x - 45}
            y={circle.y + 53}
            width="90"
            height="22"
            rx="11"
            class={if circle.offline?, do: "fill-success", else: "fill-error"}
          />
          <text
            x={circle.x}
            y={circle.y + 68}
            text-anchor="middle"
            class="fill-base-100 text-[11px] font-bold"
          >
            {if circle.offline?, do: "Back online", else: "Go offline"}
          </text>
        </g>
      </g>

      <g id="cluster-fx" phx-update="ignore"></g>
    </svg>
    <p class="text-center text-xs opacity-60 -mt-2">
      faint dots = ambient traffic &nbsp;•&nbsp; bright comet = a single goal
      leaving the node its match lives on &nbsp;•&nbsp; convoy = a node back
      online syncing its buffered backlog &nbsp;•&nbsp; box next to a node =
      messages it is buffering for an offline peer &nbsp;•&nbsp; red box = past
      the buffer, the peer will reload instead of replay
    </p>
    """
  end

  @doc """
  Whether the link between two nodes carries events right now.

  A link is up when neither end is blipped or unreachable - blip is a
  node-wide flag, so it takes down every link that touches the node.

  ## Examples

      iex> ClusterViz.link_up?(%{a: %{blip: false}, b: %{blip: false}}, :a, :b)
      true

      iex> ClusterViz.link_up?(%{a: %{blip: true}, b: %{blip: false}}, :a, :b)
      false
  """
  @spec link_up?(%{node() => map() | :unreachable}, node(), node()) :: boolean()
  def link_up?(cluster, a, b) do
    not down?(Map.get(cluster, a, :unreachable)) and not down?(Map.get(cluster, b, :unreachable))
  end

  @doc """
  The single hop a goal takes across the cluster, for the browser to animate.

  A goal is only ever broadcast by the node the match lives on, so that
  node is where the animation starts - no matter which node the browser
  is talking to. Peers behind a link that is down are dropped, so a goal
  is drawn stopping short of a node that has gone offline.

  Nodes are returned as strings, ready to be pushed to the client.

  ## Examples

      iex> cluster = %{a: %{blip: false}, b: %{blip: false}}
      iex> ClusterViz.goal_hops(cluster, [:a, :b], :b)
      [%{from: "b", to: ["a"]}]
  """
  @spec goal_hops(%{node() => map() | :unreachable}, [node()], node()) :: [
          %{from: String.t(), to: [String.t()]}
        ]
  def goal_hops(cluster, nodes, owner) do
    peers =
      for peer <- nodes, peer != owner, link_up?(cluster, owner, peer), do: Atom.to_string(peer)

    if peers == [], do: [], else: [%{from: Atom.to_string(owner), to: peers}]
  end

  @doc """
  The buffered traffic a node that just came back is about to exchange.

  Comparing two consecutive snapshots tells us which nodes went from down
  to up. For each of those, the older snapshot still holds the backlog
  that built up while it was away - what its peers queued towards it, and
  what it queued towards them - and that is what flushes the moment the
  connection is restored.

  ## Examples

      iex> was = %{a: %{blip: false, pending: %{b: 3}}, b: %{blip: true, pending: %{a: 0}}}
      iex> now = %{a: %{blip: false, pending: %{b: 0}}, b: %{blip: false, pending: %{a: 0}}}
      iex> ClusterViz.flush_streams(was, now)
      [%{from: "a", to: "b", count: 3, mode: "replay"}]
  """
  @spec flush_streams(%{node() => map() | :unreachable}, %{node() => map() | :unreachable}) :: [
          %{from: String.t(), to: String.t(), count: pos_integer(), mode: String.t()}
        ]
  def flush_streams(was, now) do
    for {recovered, status} <- now,
        down?(Map.get(was, recovered, :unreachable)),
        not down?(status),
        {peer, peer_status} <- was,
        peer != recovered,
        not down?(Map.get(now, peer, :unreachable)),
        stream <- backlog(was, peer_status, peer, recovered),
        uniq: true,
        do: stream
  end

  # Both directions of the backlog between a recovered node and one peer. A
  # stream whose sender overran its ring buffer is a "reload": the receiver's
  # cursor expired, so it reloads from the DB instead of replaying in order.
  defp backlog(was, peer_status, peer, recovered) do
    recovered_was = Map.get(was, recovered, :unreachable)

    [
      stream(peer, recovered, queued(peer_status, recovered), peer_status),
      stream(recovered, peer, queued(recovered_was, peer), recovered_was)
    ]
    |> Enum.filter(& &1)
  end

  defp stream(_from, _to, 0, _sender), do: false

  defp stream(from, to, count, sender) do
    mode = if overflowed?(count, sender), do: "reload", else: "replay"
    %{from: Atom.to_string(from), to: Atom.to_string(to), count: count, mode: mode}
  end

  defp overflowed?(count, %{capacity: capacity}) when is_integer(capacity), do: count >= capacity
  defp overflowed?(_count, _sender), do: false

  defp queued(%{pending: pending}, target), do: Map.get(pending, target, 0)
  defp queued(_status, _target), do: 0

  defp svg_height(count) when count <= 2, do: 175
  defp svg_height(_count), do: 370

  # One or two nodes sit on a line; three or more form a regular polygon
  # (triangle, square, pentagon, ...) with the first node on top.
  defp positions(nodes) do
    coords =
      case length(nodes) do
        1 ->
          [{@center_x, @line_center_y}]

        2 ->
          [{160, @line_center_y}, {560, @line_center_y}]

        count ->
          for index <- 0..(count - 1)//1 do
            angle = 2 * :math.pi() * index / count - :math.pi() / 2

            {round(@center_x + @polygon_radius * :math.cos(angle)),
             round(@polygon_center_y + @polygon_radius * :math.sin(angle))}
          end
      end

    nodes |> Enum.zip(coords) |> Map.new()
  end

  defp circles(nodes, positions, cluster, self_node) do
    for viz_node <- nodes do
      {x, y} = positions[viz_node]
      # A node with no snapshot yet (nil) reads the same as unreachable.
      status = cluster[viz_node] || :unreachable

      tone =
        cond do
          status == :unreachable -> "base-300"
          status.blip -> "error"
          true -> "success"
        end

      {missing, expired?, capacity} = missing(cluster, viz_node)
      label = short_name(viz_node) <> if viz_node == self_node, do: " (this)", else: ""
      reachable? = status != :unreachable
      offline? = reachable? and status.blip

      %{
        x: x,
        y: y,
        fill: "url(#node-#{tone})",
        halo_class: "fill-#{tone}",
        pulse?: offline?,
        label: label,
        label_width: round(String.length(label) * 7.3) + 14,
        node: Atom.to_string(viz_node),
        reachable?: reachable?,
        offline?: offline?,
        missing: min(missing, 999),
        capacity: capacity,
        overflow?: expired?,
        missing_class: if(expired?, do: "fill-error", else: "fill-warning"),
        badge_x: if(x < @center_x, do: x - 64, else: x + 26),
        info_x: if(x < @center_x, do: x - 76, else: x + 76)
      }
    end
  end

  # How many messages this node is buffering for its peers - its own producer's
  # backlog of undelivered sends. The box sits on the node holding the buffer
  # (the sender whose peer is offline, or an offline node buffering its own
  # sends), not on the peer that is merely behind. The same messages go to
  # every lagging peer, so it is the max across them, not the sum. Overflow
  # (past the ring buffer) means the lagging peer will reload instead of replay.
  defp missing(cluster, node) do
    case cluster[node] do
      %{pending: pending, capacity: capacity} ->
        buffered = pending |> Map.values() |> Enum.max(fn -> 0 end)
        {buffered, capacity != nil and buffered >= capacity, capacity}

      _unreachable ->
        {0, false, nil}
    end
  end

  defp links(nodes, positions, cluster) do
    indexed = Enum.with_index(nodes)
    center = graph_center(length(nodes))

    for {a, i} <- indexed, {b, j} <- indexed, i < j do
      healthy? = link_up?(cluster, a, b)

      %{
        path: curve(positions[a], positions[b], center),
        from: Atom.to_string(a),
        to: Atom.to_string(b),
        class: if(healthy?, do: "stroke-success link-live", else: "stroke-error link-broken"),
        healthy?: healthy?
      }
    end
  end

  defp graph_center(count) when count <= 2, do: {@center_x, @line_center_y}
  defp graph_center(_count), do: {@center_x, @polygon_center_y}

  # Bow the link away from the middle of the graph so chords do not pile up
  # on top of each other. A link whose midpoint sits on the centre has no
  # outward direction, so it bows sideways instead.
  defp curve({x1, y1}, {x2, y2}, {cx, cy}) do
    mid_x = (x1 + x2) / 2
    mid_y = (y1 + y2) / 2
    {unit_x, unit_y} = outward(mid_x - cx, mid_y - cy, x2 - x1, y2 - y1)

    control_x = round(mid_x + unit_x * @bow)
    control_y = round(mid_y + unit_y * @bow)

    "M #{x1} #{y1} Q #{control_x} #{control_y} #{x2} #{y2}"
  end

  defp outward(dx, dy, link_x, link_y) do
    case :math.sqrt(dx * dx + dy * dy) do
      distance when distance < 1.0 ->
        length = :math.sqrt(link_x * link_x + link_y * link_y)
        {-link_y / length, link_x / length}

      distance ->
        {dx / distance, dy / distance}
    end
  end

  defp down?(:unreachable), do: true
  defp down?(%{blip: blip}), do: blip

  defp short_name(node_atom) do
    node_atom |> Atom.to_string() |> String.split("@") |> hd()
  end
end
