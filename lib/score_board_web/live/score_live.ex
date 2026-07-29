defmodule ScoreBoardWeb.ScoreLive do
  @moduledoc """
  Cluster-wide scoreboard: every node's derived board side by side.

  Score a goal anywhere and watch all boards converge; a node that missed
  events shows a red, lagging cell next to the true score. Remote boards
  are read over `:erpc` — distribution, not PubSub — so the observation
  channel stays reliable even when the PubSub layer is degraded: stale
  boards cannot be demonstrated through the same channel that drops the
  data.
  """
  use ScoreBoardWeb, :live_view

  alias ScoreBoard.Blip
  alias ScoreBoard.Board
  alias ScoreBoard.Matches

  @poll_interval 1_000
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
        new_match_id: "",
        error: nil,
        blip: Blip.enabled?()
      )

    {:ok, refresh(socket)}
  end

  @impl Phoenix.LiveView
  def handle_event("create", %{"match_id" => id}, socket) do
    case id |> String.trim() |> create_match() do
      :ok ->
        {:noreply, socket |> assign(new_match_id: "", error: nil) |> refresh()}

      {:error, message} ->
        {:noreply, assign(socket, new_match_id: id, error: message)}
    end
  end

  def handle_event("goal", %{"id" => id, "team" => team}, socket) do
    case Matches.score_goal(id, team_atom(team)) do
      :ok -> {:noreply, assign(socket, error: nil)}
      {:error, :match_not_found} -> {:noreply, assign(socket, error: "match #{id} is gone")}
    end
  end

  def handle_event("blip", %{"duration" => duration}, socket) do
    Blip.on()
    Process.send_after(self(), :blip_off, String.to_integer(duration))
    {:noreply, assign(socket, blip: true)}
  end

  def handle_event("toggle-blip", _params, socket) do
    if Blip.enabled?(), do: Blip.off(), else: Blip.on()
    {:noreply, assign(socket, blip: Blip.enabled?())}
  end

  @impl Phoenix.LiveView
  def handle_info(:poll, socket) do
    Process.send_after(self(), :poll, @poll_interval)
    {:noreply, refresh(socket)}
  end

  def handle_info({:nodeup, _node}, socket), do: {:noreply, refresh(socket)}
  def handle_info({:nodedown, _node}, socket), do: {:noreply, refresh(socket)}
  def handle_info({:match_added, _id}, socket), do: {:noreply, refresh(socket)}
  def handle_info({:score_updated, _id, _score}, socket), do: {:noreply, refresh(socket)}
  def handle_info(:board_reloaded, socket), do: {:noreply, refresh(socket)}

  def handle_info(:blip_off, socket) do
    Blip.off()
    {:noreply, socket |> assign(blip: false) |> refresh()}
  end

  defp create_match(""), do: {:error, "match id can't be blank"}

  defp create_match(id) do
    case Matches.create_match(id) do
      :ok -> :ok
      {:error, :already_exists} -> {:error, "match #{id} already exists"}
    end
  end

  defp team_atom("home"), do: :home
  defp team_atom("away"), do: :away

  defp refresh(socket) do
    nodes = Enum.sort([node() | Node.list()])
    boards = Map.new(nodes, &{&1, board_on(&1)})

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

    assign(socket, nodes: nodes, boards: boards, matches: matches)
  end

  defp board_on(board_node) when board_node == node(), do: Board.scores()

  defp board_on(board_node) do
    :erpc.call(board_node, Board, :scores, [], @remote_timeout)
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

  defp fmt(nil), do: "—"
  defp fmt(%{home: home, away: away}), do: "#{home} : #{away}"

  # A cell is stale when the truth is known and this board disagrees —
  # including a missing row (the board never saw the match).
  defp stale?(_cell, nil), do: false
  defp stale?(cell, truth), do: cell != truth

  defp short_name(node_atom) do
    node_atom |> Atom.to_string() |> String.split("@") |> hd()
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

        <form phx-submit="create" class="flex justify-center gap-2">
          <input
            type="text"
            name="match_id"
            value={@new_match_id}
            placeholder="e.g. POL-GER"
            autocomplete="off"
            class="input input-bordered"
          />
          <button class="btn btn-primary">Create match</button>
        </form>
        <p :if={@error} class="text-error text-center text-sm">{@error}</p>

        <div :if={@matches != []} class="overflow-x-auto">
          <table class="table whitespace-nowrap">
            <thead>
              <tr>
                <th>Match</th>
                <th>Owner</th>
                <th class="text-center">True score</th>
                <th :for={board_node <- @nodes} class="text-center font-mono">
                  {short_name(board_node)}
                  <span :if={board_node == @node} class="badge badge-ghost badge-xs">this</span>
                  <span :if={@boards[board_node] == :unreachable} class="badge badge-error badge-xs">
                    offline
                  </span>
                </th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={match <- @matches} data-match-id={match.id}>
                <td class="font-mono">{match.id}</td>
                <td class="font-mono text-sm">{(match.owner && short_name(match.owner)) || "…"}</td>
                <td class="text-center font-mono text-lg" data-true-score-id={match.id}>
                  {fmt(match.true_score)}
                </td>
                <td
                  :for={board_node <- @nodes}
                  class={[
                    "text-center font-mono text-lg",
                    stale?(cell(@boards, board_node, match.id), match.true_score) && "text-error"
                  ]}
                  data-score-id={match.id}
                  data-node={board_node}
                >
                  {fmt(cell(@boards, board_node, match.id))}
                </td>
                <td class="text-right">
                  <button
                    class="btn btn-sm btn-primary"
                    phx-click="goal"
                    phx-value-id={match.id}
                    phx-value-team="home"
                  >
                    Goal Home
                  </button>
                  <button
                    class="btn btn-sm btn-secondary"
                    phx-click="goal"
                    phx-value-id={match.id}
                    phx-value-team="away"
                  >
                    Goal Away
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <p :if={@matches == []} class="text-center opacity-70">
          No matches yet — create one above.
        </p>

        <div class="divider">Network</div>

        <div class="flex justify-center gap-4">
          <button class="btn btn-outline" phx-click="blip" phx-value-duration="1">
            1ms blip
          </button>
          <button class="btn btn-outline" phx-click="blip" phx-value-duration="5000">
            5s outage
          </button>
          <button class="btn btn-warning" phx-click="toggle-blip">
            {if @blip, do: "Back online", else: "Go offline"}
          </button>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
