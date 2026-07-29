defmodule ScoreBoard.BoardTest do
  # The derived board is one global ETS table, so this suite is serialized
  # on purpose.
  use ExUnit.Case, async: false

  import ScoreBoard.TestHelpers

  alias ScoreBoard.Board
  alias ScoreBoard.Match
  alias ScoreBoard.Matches

  setup do
    {:ok, id: "board-#{System.unique_integer([:positive])}"}
  end

  # Broadcast puts the event in Board's mailbox before returning, and a
  # call is processed strictly after it — after this, ETS is up to date.
  defp sync, do: :sys.get_state(Board)

  defp broadcast(event) do
    Phoenix.PubSub.broadcast(ScoreBoard.PubSub, Match.topic(), event)
  end

  test "derives rows from match_created and goal events", %{id: id} do
    broadcast({:match_created, id})
    broadcast({:goal, id, :home})
    sync()

    assert {:ok, %{home: 1, away: 0}} = Board.fetch_score(id)
    assert %{home: 1, away: 0} = Map.fetch!(Board.scores(), id)
  end

  @tag capture_log: true
  test "drops a goal for an unknown match with no authoritative source", %{id: id} do
    :ok = Board.subscribe()

    broadcast({:goal, id, :away})
    sync()

    # No fabricated row: the board stays consistent and would retry the
    # authoritative recovery on the next goal. Refutes are pinned to this
    # test's id — unrelated matches restarted by Horde may notify late.
    assert :error = Board.fetch_score(id)
    refute_receive {:match_added, ^id}
    refute_receive {:score_updated, ^id, _}
  end

  test "notifies local subscribers after each applied event", %{id: id} do
    :ok = Board.subscribe()

    broadcast({:match_created, id})
    assert_receive {:match_added, ^id}

    broadcast({:goal, id, :home})
    assert_receive {:score_updated, ^id, %{home: 1, away: 0}}
  end

  test "reload/0 overwrites diverged rows from the authoritative matches", %{id: id} do
    :ok = Matches.create_match(id)
    :ok = Matches.score_goal(id, :home)
    sync()

    # Forge a goal the authoritative match never saw: the derived board
    # diverges, exactly like a board that missed or gained events.
    broadcast({:goal, id, :away})
    sync()
    assert {:ok, %{home: 1, away: 1}} = Board.fetch_score(id)

    assert :ok = Board.reload()
    assert {:ok, %{home: 1, away: 0}} = Board.fetch_score(id)
  end

  test "a restarted board rebuilds from the authoritative matches", %{id: id} do
    :ok = Matches.create_match(id)
    :ok = Matches.score_goal(id, :home)

    # Killing the board wipes its ETS table; the restarted board catches up
    # via the reload it runs in handle_continue. Wait for the old process
    # to actually die first — the kill is asynchronous, and polling before
    # that reads the old table and lets the test end mid-restart.
    old = Process.whereis(Board)
    ref = Process.monitor(old)
    Process.exit(old, :kill)
    assert_receive {:DOWN, ^ref, :process, ^old, :killed}

    assert_eventually(fn ->
      new = Process.whereis(Board)
      assert is_pid(new) and new != old
      assert {:ok, %{home: 1, away: 0}} = Board.fetch_score(id)
    end)
  end

  test "fetch_score/1 returns :error for unknown ids", %{id: id} do
    assert :error = Board.fetch_score(id)
  end
end
