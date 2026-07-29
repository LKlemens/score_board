defmodule ScoreBoardWeb.ScoreLive do
  @moduledoc """
  Live scoreboard: create matches, score goals, and watch every node's
  derived board update in real time.
  """
  use ScoreBoardWeb, :live_view

  alias ScoreBoard.Board
  alias ScoreBoard.Matches

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket), do: Board.subscribe()

    {:ok,
     assign(socket,
       page_title: "Scoreboard",
       node: node(),
       matches: load_matches(),
       new_match_id: "",
       error: nil
     )}
  end

  @impl Phoenix.LiveView
  def handle_event("create", %{"match_id" => id}, socket) do
    case id |> String.trim() |> create_match() do
      :ok ->
        {:noreply, assign(socket, matches: load_matches(), new_match_id: "", error: nil)}

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

  # All board updates re-read the derived table: it is the single local
  # source for this view, and owners may move between events (failover).
  @impl Phoenix.LiveView
  def handle_info({:match_added, _id}, socket) do
    {:noreply, assign(socket, matches: load_matches())}
  end

  def handle_info({:score_updated, _id, _score}, socket) do
    {:noreply, assign(socket, matches: load_matches())}
  end

  def handle_info(:board_reloaded, socket) do
    {:noreply, assign(socket, matches: load_matches())}
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

  defp load_matches do
    Board.scores()
    |> Enum.map(fn {id, score} ->
      # Registry sync is eventually consistent — show the owner as soon as
      # the lookup resolves.
      owner =
        case Matches.owner_node(id) do
          {:ok, owner} -> owner
          {:error, :match_not_found} -> nil
        end

      %{id: id, score: score, owner: owner}
    end)
    |> Enum.sort_by(& &1.id)
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-8">
        <div class="text-center space-y-2">
          <h1 class="text-2xl font-bold">Live Scoreboard</h1>
          <p class="text-sm opacity-70 font-mono">{@node}</p>
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

        <table :if={@matches != []} class="table">
          <thead>
            <tr>
              <th>Match</th>
              <th>Owner node</th>
              <th class="text-center">Score</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={match <- @matches} data-match-id={match.id}>
              <td class="font-mono">{match.id}</td>
              <td class="font-mono text-sm">{match.owner || "…"}</td>
              <td class="text-center font-mono text-xl" data-score-id={match.id}>
                {match.score.home} : {match.score.away}
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
        <p :if={@matches == []} class="text-center opacity-70">
          No matches yet — create one above.
        </p>
      </div>
    </Layouts.app>
    """
  end
end
