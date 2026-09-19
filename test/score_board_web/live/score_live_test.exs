defmodule ScoreBoardWeb.ScoreLiveTest do
  # Uses the global Matches/Board stack - the real end-to-end event flow.
  # All assertions are scoped to this test's unique match id, so the tests
  # can run concurrently.
  use ScoreBoardWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import ScoreBoard.TestHelpers

  alias ScoreBoard.Blip
  alias ScoreBoard.Matches

  setup %{test: test} do
    on_exit(fn -> Blip.off() end)
    {:ok, id: Atom.to_string(test)}
  end

  # The score is rendered as separately coloured spans, so the assertions
  # read the cell's text rather than its markup.
  defp score_cell(view, id), do: text(view, ~s{[data-score-id="#{id}"]})

  defp true_score_cell(view, id), do: text(view, ~s{[data-true-score-id="#{id}"]})

  defp text(view, selector) do
    view
    |> element(selector)
    |> render()
    |> String.replace(~r/<[^>]*>/, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  test "renders the node name", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ Atom.to_string(node())
  end

  test "renders the cluster visualization with this node", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    svg = view |> element("#cluster-viz") |> render()
    assert svg =~ "fill-success"
    assert svg =~ node() |> Atom.to_string() |> String.split("@") |> hd()
  end

  test "a created match shows up on the board", %{conn: conn, id: id} do
    :ok = Matches.create_match(id)
    {:ok, view, _html} = live(conn, ~p"/")

    assert_eventually(fn -> assert score_cell(view, id) =~ "0 : 0" end)
  end

  test "goal buttons update the score", %{conn: conn, id: id} do
    :ok = Matches.create_match(id)
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element(~s{[data-match-id="#{id}"] button}, "Goal Home") |> render_click()

    assert_eventually(fn ->
      assert score_cell(view, id) =~ "1 : 0"
      assert true_score_cell(view, id) =~ "1 : 0"
    end)
  end

  test "the per-node toggle flips this node's fault injection and the badge", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    toggle = ~s{#cluster-viz [phx-value-node="#{node()}"]}

    view |> element(toggle) |> render_click()
    assert Blip.enabled?()
    assert view |> element("#net-status") |> render() =~ "offline"

    view |> element(toggle) |> render_click()
    refute Blip.enabled?()
    assert view |> element("#net-status") |> render() =~ "connected"
  end

  test "the visualization exposes the anchors the goal animation needs", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    svg = view |> element("#cluster-viz") |> render()
    assert svg =~ ~s{phx-hook="ClusterFx"}
    assert svg =~ ~s{id="cluster-fx"}
    assert svg =~ ~s{data-node-dot="#{node()}"}
  end

  test "scoring a goal pushes the route the goal takes", %{conn: conn, id: id} do
    :ok = Matches.create_match(id)
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element(~s{[data-match-id="#{id}"] button}, "Goal Away") |> render_click()

    # The test cluster is a single node that owns its own matches, so the
    # goal has nowhere to travel; ClusterVizTest covers the routing itself.
    assert_push_event(view, "goal-flight", %{team: "away", hops: []})
  end

  test "goals scored elsewhere show up live", %{conn: conn, id: id} do
    :ok = Matches.create_match(id)
    {:ok, view, _html} = live(conn, ~p"/")

    :ok = Matches.score_goal(id, :away)

    assert_eventually(fn ->
      assert score_cell(view, id) =~ "0 : 1"
    end)
  end
end
