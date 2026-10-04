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

  describe "the process graph" do
    test "shows VMs, their processes and a legend, and hides on demand", %{conn: conn, id: id} do
      Matches.create_match(id)
      {:ok, view, html} = live(conn, ~p"/")

      # Collapsed on arrival: only the header is there.
      assert html =~ "What runs behind this board"
      refute html =~ "One process per match"
      refute html =~ "unique in the cluster"

      view |> element("button", "What runs behind this board") |> render_click()

      assert_eventually(fn ->
        shown = render(view)
        assert shown =~ "One process per match"
        assert shown =~ "BEAM VM"
        assert shown =~ "board process"
        assert shown =~ "unique in the cluster"
      end)

      hidden = view |> element("button", "What runs behind this board") |> render_click()

      # Hiding takes the explanation with it - it lives in the same section.
      refute hidden =~ "unique in the cluster"
      refute hidden =~ "One process per match"
      assert hidden =~ "What runs behind this board"
    end

    test "explains matches, broadcasting and the local boards", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      html = view |> element("button", "What runs behind this board") |> render_click()

      assert html =~ "Each match is a single process living on one node"
      assert html =~ "keeping each match&#39;s score in an ETS table"
      assert html =~ "listens"
      assert html =~ "writes them to its own ETS table"
      assert html =~ "bottleneck"
    end
  end

  describe "node identity" do
    test "the table explains that a column is a node", %{conn: conn, id: id} do
      Matches.create_match(id)
      {:ok, view, _html} = live(conn, ~p"/")

      assert_eventually(fn -> assert render(view) =~ "one column per node" end)
    end

    test "a column header carries the full node name", %{conn: conn, id: id} do
      Matches.create_match(id)
      {:ok, view, _html} = live(conn, ~p"/")

      assert_eventually(fn -> assert render(view) =~ ~s(title="#{node()}") end)
    end
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
