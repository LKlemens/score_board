defmodule ScoreBoard.MatchesTest do
  # Matches live in the global Horde registry and boards share one ETS
  # table, so this suite is serialized on purpose.
  use ExUnit.Case, async: false

  import ScoreBoard.TestHelpers

  alias ScoreBoard.Board
  alias ScoreBoard.Matches

  setup do
    {:ok, id: "match-#{System.unique_integer([:positive])}"}
  end

  test "create_match/1 starts and registers a match once", %{id: id} do
    assert :ok = Matches.create_match(id)
    assert id in Matches.list_matches()
    assert {:ok, owner} = Matches.owner_node(id)
    assert owner == node()

    assert {:error, :already_exists} = Matches.create_match(id)
  end

  test "score_goal/2 updates the authoritative score and boards derive it", %{id: id} do
    :ok = Matches.create_match(id)

    assert :ok = Matches.score_goal(id, :home)
    assert :ok = Matches.score_goal(id, :away)
    assert :ok = Matches.score_goal(id, :home)

    assert {:ok, %{home: 2, away: 1}} = Matches.authoritative_score(id)

    assert_eventually(fn ->
      assert {:ok, %{home: 2, away: 1}} = Board.fetch_score(id)
    end)
  end

  test "unknown matches return errors", %{id: id} do
    assert {:error, :match_not_found} = Matches.score_goal(id, :home)
    assert {:error, :match_not_found} = Matches.authoritative_score(id)
    assert {:error, :match_not_found} = Matches.owner_node(id)
  end

  test "a restarted match restores its score from the local board", %{id: id} do
    :ok = Matches.create_match(id)
    :ok = Matches.score_goal(id, :home)
    :ok = Matches.score_goal(id, :away)

    assert_eventually(fn ->
      assert {:ok, %{home: 1, away: 1}} = Board.fetch_score(id)
    end)

    id |> Matches.via() |> GenServer.whereis() |> Process.exit(:kill)

    assert_eventually(fn ->
      assert {:ok, %{home: 1, away: 1}} = Matches.authoritative_score(id)
    end)
  end
end
