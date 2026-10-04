defmodule ScoreBoardWeb.ScoreLiveTest do
  # Shares the app-wide lane pool (each test takes and releases one lane), so
  # the suite runs serially. Assertions are scoped to this test's match id.
  use ScoreBoardWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import ScoreBoard.TestHelpers

  alias ScoreBoard.Blip
  alias ScoreBoard.Lane
  alias ScoreBoard.Lanes
  alias ScoreBoard.Matches

  setup %{test: test} do
    tenant = Atom.to_string(test)
    {:ok, lane} = Lanes.assign(tenant)

    on_exit(fn ->
      Blip.off(lane)
      Lanes.release(tenant)
    end)

    conn = init_test_session(build_conn(), %{"tenant" => tenant})
    {:ok, conn: conn, tenant: tenant, lane: lane, id: Atom.to_string(test)}
  end

  describe "the process graph" do
    test "shows VMs, their processes and a legend, and hides on demand", %{
      conn: conn,
      lane: lane,
      id: id
    } do
      Matches.create_match(lane, id)
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
  end

  describe "introduction" do
    test "explains matches, broadcasting and the local boards", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      html = view |> element("button", "What runs behind this board") |> render_click()

      assert html =~ "Each match is a single process"
      assert html =~ "listens"
      assert html =~ "writes them to its own ETS table"
      assert html =~ "keeping each match&#39;s score in an ETS table"
      assert html =~ "bottleneck"
    end
  end

  describe "node identity" do
    test "the table explains that a column is a node", %{conn: conn, lane: lane, id: id} do
      Matches.create_match(lane, id)
      {:ok, view, _html} = live(conn, ~p"/")

      assert_eventually(fn -> assert render(view) =~ "one column per node" end)
    end

    test "a column header carries the full node name", %{conn: conn, lane: lane, id: id} do
      Matches.create_match(lane, id)
      {:ok, view, _html} = live(conn, ~p"/")

      assert_eventually(fn -> assert render(view) =~ ~s(title="#{node()}") end)
    end
  end

  describe "idle expiry" do
    test "the page turns static when the lane expires", %{conn: conn, tenant: tenant} do
      {:ok, view, html} = live(conn, ~p"/")
      refute html =~ "Your session is gone"

      Phoenix.PubSub.broadcast(ScoreBoard.PubSub, Lanes.topic(tenant), :lane_expired)

      assert render(view) =~ "Your session is gone"
      assert render(view) =~ "Start a new one"
    end
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

  test "a created match shows up on the board", %{conn: conn, lane: lane, id: id} do
    :ok = Matches.create_match(lane, id)
    {:ok, view, _html} = live(conn, ~p"/")

    assert_eventually(fn -> assert score_cell(view, id) =~ "0 : 0" end)
  end

  test "goal buttons update the score", %{conn: conn, lane: lane, id: id} do
    :ok = Matches.create_match(lane, id)
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element(~s{[data-match-id="#{id}"] button}, "Goal Home") |> render_click()

    assert_eventually(fn ->
      assert score_cell(view, id) =~ "1 : 0"
      assert true_score_cell(view, id) =~ "1 : 0"
    end)
  end

  test "the per-node toggle flips this lane's fault injection and the badge", %{
    conn: conn,
    lane: lane
  } do
    {:ok, view, _html} = live(conn, ~p"/")

    toggle = ~s{#cluster-viz [phx-value-node="#{node()}"]}

    view |> element(toggle) |> render_click()
    assert Blip.enabled?(lane)
    assert view |> element("#net-status") |> render() =~ "offline"

    view |> element(toggle) |> render_click()
    refute Blip.enabled?(lane)
    assert view |> element("#net-status") |> render() =~ "connected"
  end

  test "the visualization exposes the anchors the goal animation needs", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    svg = view |> element("#cluster-viz") |> render()
    assert svg =~ ~s{phx-hook="ClusterFx"}
    assert svg =~ ~s{id="cluster-fx"}
    assert svg =~ ~s{data-node-dot="#{node()}"}
  end

  test "scoring a goal pushes the route the goal takes", %{conn: conn, lane: lane, id: id} do
    :ok = Matches.create_match(lane, id)
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element(~s{[data-match-id="#{id}"] button}, "Goal Away") |> render_click()

    # The test cluster is a single node that owns its own matches, so the
    # goal has nowhere to travel; ClusterVizTest covers the routing itself.
    assert_push_event(view, "goal-flight", %{team: "away", hops: []})
  end

  test "goals scored elsewhere show up live", %{conn: conn, lane: lane, id: id} do
    :ok = Matches.create_match(lane, id)
    {:ok, view, _html} = live(conn, ~p"/")

    :ok = Matches.score_goal(lane, id, :away)

    assert_eventually(fn ->
      assert score_cell(view, id) =~ "0 : 1"
    end)
  end

  test "a freshly assigned lane opens a match on each node", %{conn: conn, lane: lane} do
    me = node()
    {:ok, _view, _html} = live(conn, ~p"/")

    assert_eventually(fn ->
      ids = Matches.list_matches(lane)
      assert ids != []
      for match_id <- ids, do: assert({:ok, ^me} = Matches.owner_node(lane, match_id))
    end)
  end

  test "a full pool shows the busy page instead of crashing" do
    # setup already holds one lane; take the rest, then a new tenant is refused.
    drainers = for i <- 1..(Lane.count() - 1), do: "drain-#{i}"
    on_exit(fn -> Enum.each(drainers, &Lanes.release/1) end)
    Enum.each(drainers, fn tenant -> assert {:ok, _lane} = Lanes.assign(tenant) end)

    conn = init_test_session(build_conn(), %{"tenant" => "no-lane-#{System.unique_integer()}"})
    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "busy"
  end
end
