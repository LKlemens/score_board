defmodule ScoreBoardWeb.StatsLiveTest do
  use ScoreBoardWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import ScoreBoard.TestHelpers

  alias ScoreBoard.Stats

  test "shows the counters and the lane gauge", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/stats")

    assert html =~ "Demo stats"
    assert html =~ "Online now"
    assert html =~ "Lane pool"
    assert html =~ "taken"
  end

  test "a visitor shows up in the online count", %{conn: conn} do
    {:ok, pid} = Agent.start_link(fn -> :visitor end)
    on_exit(fn -> if Process.alive?(pid), do: Agent.stop(pid) end)
    Stats.visit("stats-live-visitor", pid)
    assert_eventually(fn -> assert Stats.snapshot().online >= 1 end)

    online = Stats.snapshot().online
    {:ok, view, _html} = live(conn, ~p"/stats")

    assert view |> element("[data-stat=online]") |> render() =~ to_string(online)
  end

  test "says so when no database is configured", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/stats")

    assert html =~ "No database configured"
  end
end
