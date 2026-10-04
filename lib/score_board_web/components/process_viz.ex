defmodule ScoreBoardWeb.ProcessViz do
  @moduledoc """
  The processes behind the scoreboard, drawn from live state.

  One box per node - a BEAM VM - holding the match processes that happen to run
  there and that node's board process, with the rows it holds in its ETS table.
  The dashed line underneath is the hop between nodes: a goal reaches the local
  board inside the VM, and crosses to the other nodes over that link.

  Nothing here is decorative: a match pill moves to another VM when Horde
  places it elsewhere, and a board turns red when its node is unreachable.
  """
  use Phoenix.Component

  @width 720
  @vm_top 26
  @vm_padding 10
  @pill_height 26
  @pill_gap 8
  @row_height 15
  @board_header 20
  # Height below the VM boxes for the node-to-node bus and its caption.
  @bus_space 50

  attr :nodes, :list, required: true, doc: "sorted cluster nodes"

  attr :matches, :list,
    required: true,
    doc: "%{id: _, owner: node | nil, true_score: score | nil} entries"

  attr :boards, :map, required: true, doc: "node => %{match_id => score} | :unreachable"
  attr :node, :atom, required: true, doc: "the node serving this page"

  def process_map(assigns) do
    columns = columns(assigns)
    height = height(columns)

    assigns =
      assigns
      |> assign(:columns, columns)
      |> assign(:height, height)
      |> assign(:unplaced, for(m <- assigns.matches, m.owner == nil, do: m.id))
      # Module attributes are not in scope inside ~H, where @name reads assigns.
      |> assign(width: @width, vm_top: @vm_top, pill_height: @pill_height)
      |> assign(board_header: @board_header, row_height: @row_height)
      |> assign(vm_bottom: vm_bottom(height), bus_y: vm_bottom(height) + 18)

    ~H"""
    <svg viewBox={"0 0 #{@width} #{@height}"} class="w-full max-w-4xl mx-auto">
      <g :if={length(@columns) > 1}>
        <line
          x1={List.first(@columns).center}
          y1={@bus_y}
          x2={List.last(@columns).center}
          y2={@bus_y}
          class="stroke-primary opacity-50"
          stroke-width="2"
          stroke-dasharray="6 5"
        />
        <line
          :for={column <- @columns}
          x1={column.center}
          y1={@vm_bottom}
          x2={column.center}
          y2={@bus_y}
          class="stroke-primary opacity-50"
          stroke-width="2"
          stroke-dasharray="6 5"
        />
        <circle
          :for={column <- @columns}
          cx={column.center}
          cy={@bus_y}
          r="3.5"
          class="fill-primary opacity-70"
        />
        <text
          x={@width / 2}
          y={@bus_y + 18}
          text-anchor="middle"
          class="fill-current text-[11px] opacity-70"
        >
          goals broadcast between nodes
        </text>
      </g>

      <g :for={column <- @columns}>
        <rect
          x={column.x}
          y={@vm_top}
          width={column.width}
          height={@vm_bottom - @vm_top}
          rx="12"
          class={[
            "fill-base-200/40",
            if(column.offline?, do: "stroke-error", else: "stroke-base-content/30")
          ]}
          stroke-width="2"
        />
        <text
          x={column.center}
          y={@vm_top - 8}
          text-anchor="middle"
          class="fill-current text-[12px] font-bold font-mono cursor-help"
        >
          <title>{column.node}</title>
          {column.short_name} · BEAM VM
        </text>

        <g :for={match <- column.matches}>
          <rect
            x={column.center - 62}
            y={match.y}
            width="124"
            height={@pill_height}
            rx="13"
            class="fill-base-100 stroke-primary"
            stroke-width="1.5"
          />
          <text
            x={column.center}
            y={match.y + 17}
            text-anchor="middle"
            class="fill-current text-[11px] font-mono"
          >
            {match.label}
          </text>
        </g>

        <text
          :if={column.matches == []}
          x={column.center}
          y={column.matches_top + 16}
          text-anchor="middle"
          class="fill-current text-[11px] opacity-40 italic"
        >
          no match process here
        </text>

        <rect
          x={column.x + 12}
          y={column.board_y}
          width={column.width - 24}
          height={column.board_height}
          rx="10"
          class={[
            "fill-base-100",
            if(column.offline?, do: "stroke-error", else: "stroke-success")
          ]}
          stroke-width="2"
        />
        <text
          x={column.center}
          y={column.board_y + 15}
          text-anchor="middle"
          class="fill-current text-[11px] font-bold"
        >
          board process · ETS
        </text>
        <text
          :for={{row, index} <- Enum.with_index(column.rows)}
          x={column.center}
          y={column.board_y + @board_header + 12 + index * @row_height}
          text-anchor="middle"
          class="fill-current text-[10px] font-mono opacity-80"
        >
          {row}
        </text>
      </g>

      <text
        :if={@unplaced != []}
        x={@width / 2}
        y={@height - 1}
        text-anchor="middle"
        class="fill-current text-[10px] opacity-50 italic"
      >
        being placed: {Enum.join(@unplaced, ", ")}
      </text>
    </svg>
    """
  end

  @doc """
  Key to the shapes in `process_map/1`.

  Drawn with the same classes as the graph itself, so a change there shows up
  here rather than drifting out of date in prose.
  """
  def legend(assigns) do
    ~H"""
    <div class="flex flex-wrap justify-center gap-x-6 gap-y-2 text-xs">
      <span class="flex items-center gap-2">
        <svg viewBox="0 0 40 20" class="w-10 h-5 shrink-0">
          <rect
            x="1"
            y="1"
            width="38"
            height="18"
            rx="6"
            class="fill-base-200/40 stroke-base-content/30"
            stroke-width="2"
          />
        </svg>
        <span><b>BEAM VM</b> - one node</span>
      </span>

      <span class="flex items-center gap-2">
        <svg viewBox="0 0 40 20" class="w-10 h-5 shrink-0">
          <rect
            x="1"
            y="3"
            width="38"
            height="14"
            rx="7"
            class="fill-base-100 stroke-primary"
            stroke-width="1.5"
          />
        </svg>
        <span><b>match process</b> - unique in the cluster</span>
      </span>

      <span class="flex items-center gap-2">
        <svg viewBox="0 0 40 20" class="w-10 h-5 shrink-0">
          <rect
            x="1"
            y="2"
            width="38"
            height="16"
            rx="5"
            class="fill-base-100 stroke-success"
            stroke-width="2"
          />
        </svg>
        <span><b>board process</b> - that node's scores copy</span>
      </span>
    </div>
    """
  end

  defp columns(assigns) do
    %{nodes: nodes, matches: matches, boards: boards, node: self_node} = assigns
    count = max(length(nodes), 1)
    step = @width / count
    tallest = tallest_stack(nodes, matches)

    for {node, index} <- Enum.with_index(nodes) do
      owned = for match <- matches, match.owner == node, do: match
      rows = rows(boards[node])
      matches_top = @vm_top + @vm_padding + 14
      board_y = matches_top + tallest * (@pill_height + @pill_gap) + 10

      %{
        node: Atom.to_string(node),
        short_name: short_name(node) <> if(node == self_node, do: " (this)", else: ""),
        x: round(step * index) + 8,
        width: round(step) - 16,
        center: round(step * index + step / 2),
        offline?: boards[node] == :unreachable,
        matches_top: matches_top,
        matches: pills(owned, matches_top),
        board_y: board_y,
        board_height: @board_header + max(length(rows), 1) * @row_height + 6,
        rows: rows
      }
    end
  end

  # Every VM is drawn the same height, so the boards line up across the row.
  defp tallest_stack(nodes, matches) do
    nodes
    |> Enum.map(fn node -> Enum.count(matches, &(&1.owner == node)) end)
    |> Enum.max(fn -> 0 end)
    |> max(1)
  end

  defp pills(matches, top) do
    for {match, index} <- Enum.with_index(matches) do
      %{label: label(match), y: top + index * (@pill_height + @pill_gap)}
    end
  end

  # The score the match process itself holds - the truth every board copies.
  defp label(%{id: id} = match) do
    case Map.get(match, :true_score) do
      %{home: home, away: away} -> "#{id}  #{home}:#{away}"
      _missing -> id
    end
  end

  defp rows(:unreachable), do: ["unreachable"]
  defp rows(nil), do: ["no rows yet"]
  defp rows(scores) when map_size(scores) == 0, do: ["no rows yet"]

  defp rows(scores) do
    scores
    |> Enum.sort_by(fn {id, _score} -> id end)
    |> Enum.map(fn {id, %{home: home, away: away}} -> "#{id}  #{home}:#{away}" end)
  end

  # Room for the tallest VM, then the bus line and its label underneath.
  defp height(columns) do
    columns
    |> Enum.map(&(&1.board_y + &1.board_height))
    |> Enum.max(fn -> 160 end)
    |> Kernel.+(@bus_space)
  end

  defp vm_bottom(height), do: height - @bus_space + 10

  defp short_name(node_atom) do
    node_atom |> Atom.to_string() |> String.split("@") |> hd()
  end
end
