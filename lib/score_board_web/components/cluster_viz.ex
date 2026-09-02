defmodule ScoreBoardWeb.ClusterViz do
  @moduledoc """
  Animated SVG of the cluster.

  Nodes are laid out as a regular polygon (triangle for 3, square for 4,
  and so on; one or two nodes sit on a horizontal line). Healthy links
  carry traveling message dots; a link to a blipped or unreachable node
  turns red. The box beside a lagging node counts the messages it is
  missing - queued at its peers, flushed once the connection is back; red
  once past the ring buffer, when the node will reload instead of replay.
  """
  use Phoenix.Component

  @center_x 360
  @polygon_radius 115
  @polygon_center_y 155

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
    <svg id="cluster-viz" viewBox={"0 0 720 #{@height}"} class="w-full max-w-3xl mx-auto">
      <g :for={link <- @links}>
        <path d={link.path} class={link.class} fill="none" stroke-width="2.5" />
        <g :if={link.healthy?}>
          <circle r="5" class="fill-primary">
            <animateMotion dur="1.6s" repeatCount="indefinite" path={link.path} />
          </circle>
          <circle r="5" class="fill-primary opacity-60">
            <animateMotion
              dur="1.6s"
              begin="-0.8s"
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
        <circle cx={circle.x} cy={circle.y} r="20" class={circle.class} />
        <g :if={circle.missing > 0}>
          <rect
            x={circle.x + 26}
            y={circle.y - 12}
            width="38"
            height="24"
            rx="6"
            class={circle.missing_class}
          />
          <text
            x={circle.x + 45}
            y={circle.y + 4}
            text-anchor="middle"
            class="fill-base-100 text-[12px] font-bold"
          >
            {circle.missing}
          </text>
          <g class="cursor-help">
            <title>
              Messages this node is missing.
              Orange: queued at its peers and replayed in order once the
              connection is back.
              Red: past the ring-buffer capacity - the node will receive
              cursor_expired and reload from the match processes instead.
            </title>
            <circle cx={circle.x + 76} cy={circle.y} r="9" class="fill-info opacity-80" />
            <text
              x={circle.x + 76}
              y={circle.y + 4}
              text-anchor="middle"
              class="fill-base-100 text-[11px] font-bold italic"
            >
              i
            </text>
          </g>
        </g>
        <text
          x={circle.x}
          y={circle.y + 40}
          text-anchor="middle"
          class="fill-current text-[12px] font-mono"
        >
          {circle.label}
        </text>
        <g
          :if={circle.reachable?}
          class="cursor-pointer"
          phx-click="toggle-node"
          phx-value-node={circle.node}
        >
          <rect
            x={circle.x - 45}
            y={circle.y + 50}
            width="90"
            height="22"
            rx="6"
            class={if circle.offline?, do: "fill-success", else: "fill-warning"}
          />
          <text
            x={circle.x}
            y={circle.y + 65}
            text-anchor="middle"
            class="fill-base-100 text-[11px] font-bold"
          >
            {if circle.offline?, do: "Back online", else: "Go offline"}
          </text>
        </g>
      </g>
    </svg>
    <p class="text-center text-xs opacity-60 -mt-2">
      dots = events flowing &nbsp;•&nbsp; box next to a node = messages it is
      missing &nbsp;•&nbsp; red box = past the buffer, node will reload
      instead of replay
    </p>
    """
  end

  defp svg_height(count) when count <= 2, do: 160
  defp svg_height(_count), do: 360

  # One or two nodes sit on a line; three or more form a regular polygon
  # (triangle, square, pentagon, ...) with the first node on top.
  defp positions(nodes) do
    coords =
      case length(nodes) do
        1 ->
          [{@center_x, 70}]

        2 ->
          [{160, 70}, {560, 70}]

        count ->
          for index <- 0..(count - 1) do
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
      status = cluster[viz_node]

      class =
        cond do
          status == :unreachable -> "fill-base-300"
          status.blip -> "fill-error animate-pulse"
          true -> "fill-success"
        end

      {missing, capacity} = missing(cluster, viz_node)
      full? = capacity != nil and missing >= capacity
      label = short_name(viz_node) <> if viz_node == self_node, do: " (this)", else: ""
      reachable? = status != :unreachable
      offline? = reachable? and status.blip

      %{
        x: x,
        y: y,
        class: class,
        label: label,
        node: Atom.to_string(viz_node),
        reachable?: reachable?,
        offline?: offline?,
        missing: min(missing, 999),
        missing_class: if(full?, do: "fill-error", else: "fill-warning")
      }
    end
  end

  # How many messages this node is missing: every peer queues (roughly)
  # the same backlog towards it, so the maximum across senders is the one
  # number worth showing - no sum. Also returns that sender's ring-buffer
  # capacity: past it, the node's cursor expires and it reloads instead of
  # replaying.
  defp missing(cluster, receiver) do
    cluster
    |> Map.delete(receiver)
    |> Map.values()
    |> Enum.map(fn
      %{pending: pending, capacity: capacity} -> {Map.get(pending, receiver, 0), capacity}
      _unreachable -> {0, nil}
    end)
    |> Enum.max_by(fn {count, _capacity} -> count end, fn -> {0, nil} end)
  end

  defp links(nodes, positions, cluster) do
    indexed = Enum.with_index(nodes)

    for {a, i} <- indexed, {b, j} <- indexed, i < j do
      {x1, y1} = positions[a]
      {x2, y2} = positions[b]
      broken? = down?(cluster[a]) or down?(cluster[b])

      %{
        path: "M #{x1} #{y1} L #{x2} #{y2}",
        class: if(broken?, do: "stroke-error link-broken", else: "stroke-success link-live"),
        healthy?: not broken?
      }
    end
  end

  defp down?(:unreachable), do: true
  defp down?(%{blip: blip}), do: blip

  defp short_name(node_atom) do
    node_atom |> Atom.to_string() |> String.split("@") |> hd()
  end
end
