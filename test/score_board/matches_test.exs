defmodule ScoreBoard.MatchesTest do
  # Matches live in the global Horde registry and the shared default board,
  # but every assertion is scoped to this test's unique id, so the tests
  # can run concurrently.
  use ExUnit.Case, async: true

  import ScoreBoard.TestHelpers

  alias ScoreBoard.Board
  alias ScoreBoard.Matches

  setup %{test: test} do
    {:ok, id: Atom.to_string(test)}
  end

  test "create_match/1 starts and registers a match once", %{id: id} do
    assert :ok = Matches.create_match(id)
    assert id in Matches.list_matches()
    assert {:ok, owner} = Matches.owner_node(id)
    assert owner == node()

    assert {:error, :already_exists} = Matches.create_match(id)
  end

  test "score_goal/2 updates the true score and boards derive it", %{id: id} do
    :ok = Matches.create_match(id)

    assert :ok = Matches.score_goal(id, :home)
    assert :ok = Matches.score_goal(id, :away)
    assert :ok = Matches.score_goal(id, :home)

    assert {:ok, %{home: 2, away: 1}} = Matches.score(id)

    assert_eventually(fn ->
      assert {:ok, %{home: 2, away: 1}} = Board.fetch_score(id)
    end)
  end

  test "claim_one/0 claims this node's fixture, idempotently" do
    node = node()

    assert {:ok, claimed} = Matches.claim_one()
    assert claimed in Matches.list_matches()
    assert {:ok, ^node} = Matches.owner_node(claimed)
    assert {:ok, %{home: 0, away: 0}} = Matches.score(claimed)

    # Deterministic by node ordinal: re-claiming yields the same fixture.
    assert {:ok, ^claimed} = Matches.claim_one()
  end

  test "unknown matches return errors", %{id: id} do
    assert {:error, :match_not_found} = Matches.score_goal(id, :home)
    assert {:error, :match_not_found} = Matches.score(id)
    assert {:error, :match_not_found} = Matches.owner_node(id)
  end

  test "a restarted match re-seeds its score from the DB", %{id: id} do
    :ok = Matches.create_match(id)
    :ok = Matches.score_goal(id, :home)
    :ok = Matches.score_goal(id, :away)

    assert_eventually(fn ->
      assert {:ok, %{home: 1, away: 1}} = Board.fetch_score(id)
    end)

    id |> Matches.via() |> GenServer.whereis() |> Process.exit(:kill)

    assert_eventually(fn ->
      assert {:ok, %{home: 1, away: 1}} = Matches.score(id)
    end)
  end
end
