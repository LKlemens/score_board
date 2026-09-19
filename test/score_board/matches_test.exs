defmodule ScoreBoard.MatchesTest do
  # Each test runs in its own lane (unique Horde key prefix + its own board),
  # so assertions never collide - async safe.
  use ExUnit.Case, async: true

  import ScoreBoard.TestHelpers

  alias ScoreBoard.Board
  alias ScoreBoard.Matches

  setup %{test: test} do
    lane = start_lane(test)
    {:ok, lane: lane, id: Atom.to_string(test)}
  end

  test "create_match/2 starts and registers a match once", %{lane: lane, id: id} do
    assert :ok = Matches.create_match(lane, id)
    assert id in Matches.list_matches(lane)
    assert {:ok, owner} = Matches.owner_node(lane, id)
    assert owner == node()

    assert {:error, :already_exists} = Matches.create_match(lane, id)
  end

  test "score_goal/3 updates the true score and the board derives it", %{lane: lane, id: id} do
    :ok = Matches.create_match(lane, id)

    assert :ok = Matches.score_goal(lane, id, :home)
    assert :ok = Matches.score_goal(lane, id, :away)
    assert :ok = Matches.score_goal(lane, id, :home)

    assert {:ok, %{home: 2, away: 1}} = Matches.score(lane, id)

    assert_eventually(fn ->
      assert {:ok, %{home: 2, away: 1}} = Board.fetch_score(lane, id)
    end)
  end

  test "matches are isolated per lane", %{lane: lane, id: id} do
    other = start_lane(:"#{id}-lane2")
    :ok = Matches.create_match(lane, id)

    assert id in Matches.list_matches(lane)
    refute id in Matches.list_matches(other)
  end

  test "unknown matches return errors", %{lane: lane, id: id} do
    assert {:error, :match_not_found} = Matches.score_goal(lane, id, :home)
    assert {:error, :match_not_found} = Matches.score(lane, id)
    assert {:error, :match_not_found} = Matches.owner_node(lane, id)
  end

  test "a restarted match re-seeds its score from the DB", %{lane: lane, id: id} do
    :ok = Matches.create_match(lane, id)
    :ok = Matches.score_goal(lane, id, :home)
    :ok = Matches.score_goal(lane, id, :away)

    assert_eventually(fn ->
      assert {:ok, %{home: 1, away: 1}} = Board.fetch_score(lane, id)
    end)

    lane |> Matches.via(id) |> GenServer.whereis() |> Process.exit(:kill)

    assert_eventually(fn ->
      assert {:ok, %{home: 1, away: 1}} = Matches.score(lane, id)
    end)
  end
end
