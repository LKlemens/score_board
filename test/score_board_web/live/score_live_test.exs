defmodule ScoreBoardWeb.ScoreLiveTest do
  # Uses the global Matches/Board stack — the real end-to-end event flow.
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

  defp score_cell(view, id) do
    view |> element(~s{[data-score-id="#{id}"]}) |> render()
  end

  test "renders the node name and the create form", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ Atom.to_string(node())
    assert html =~ "Create match"
  end

  test "creating a match adds it to the board", %{conn: conn, id: id} do
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("form") |> render_submit(%{"match_id" => id})

    assert score_cell(view, id) =~ "0 : 0"
  end

  test "a duplicate or blank match id shows an error", %{conn: conn, id: id} do
    {:ok, view, _html} = live(conn, ~p"/")

    :ok = Matches.create_match(id)
    assert view |> element("form") |> render_submit(%{"match_id" => id}) =~ "already exists"
    assert view |> element("form") |> render_submit(%{"match_id" => "  "}) =~ "blank"
  end

  test "goal buttons update the score", %{conn: conn, id: id} do
    :ok = Matches.create_match(id)
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element(~s{[data-match-id="#{id}"] button}, "Goal Home") |> render_click()

    assert_eventually(fn ->
      assert score_cell(view, id) =~ "1 : 0"
      assert view |> element(~s{[data-true-score-id="#{id}"]}) |> render() =~ "1 : 0"
    end)
  end

  test "blip toggle flips fault injection and the badge", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("button", "Go offline") |> render_click()
    assert Blip.enabled?()
    assert view |> element("#net-status") |> render() =~ "offline"

    view |> element("button", "Back online") |> render_click()
    refute Blip.enabled?()
    assert view |> element("#net-status") |> render() =~ "connected"
  end

  test "timed blip presets recover automatically", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("button", "1ms blip") |> render_click()

    assert_eventually(fn ->
      refute Blip.enabled?()
      assert view |> element("#net-status") |> render() =~ "connected"
    end)
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
