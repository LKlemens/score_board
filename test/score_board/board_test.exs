defmodule ScoreBoard.BoardTest do
  # Each test runs its own lane (own board, DB, and event bus), so tests never
  # share state - async safe.
  use ExUnit.Case, async: true

  import ScoreBoard.TestHelpers

  alias ScoreBoard.Blip
  alias ScoreBoard.Board
  alias ScoreBoard.DB
  alias ScoreBoard.Lane
  alias ScoreBoard.Match
  alias ScoreBoard.Matches

  setup %{test: test} do
    lane = start_lane(test)
    {:ok, lane: lane, id: Atom.to_string(test)}
  end

  # Broadcast puts the event in the board's mailbox before returning, and a
  # call is processed strictly after it - after this, ETS is up to date.
  defp sync(lane), do: :sys.get_state(Lane.board(lane))

  defp broadcast(lane, event) do
    ScoreBoard.EchoPubSub.broadcast(Lane.pubsub(lane), Match.topic(), event)
  end

  test "derives rows from match_created and goal events", %{lane: lane, id: id} do
    broadcast(lane, {:match_created, id, %{home: 0, away: 0}, self()})
    broadcast(lane, {:goal, id, :home})
    sync(lane)

    assert {:ok, %{home: 1, away: 0}} = Board.fetch_score(lane, id)
    assert %{home: 1, away: 0} = Map.fetch!(Board.scores(lane), id)
  end

  @tag capture_log: true
  test "drops a goal for an unknown match with no DB entry", %{lane: lane, id: id} do
    :ok = Board.subscribe(lane)

    broadcast(lane, {:goal, id, :away})
    sync(lane)

    assert :error = Board.fetch_score(lane, id)
    refute_receive {:match_added, ^id}
    refute_receive {:score_updated, ^id, _}
  end

  test "goal for an unknown match recovers the full true score", %{lane: lane, id: id} do
    # The true score is in the DB but this board never saw the match created
    # (it missed the events). The next goal must force a recovery from the DB -
    # the full 2:0 - not a fabricated row counted from zero.
    :ok = DB.write(lane, id, %{home: 2, away: 0})

    broadcast(lane, {:goal, id, :away})
    sync(lane)

    assert_eventually(fn -> assert {:ok, %{home: 2, away: 0}} = Board.fetch_score(lane, id) end)
  end

  test "notifies local subscribers after each applied event", %{lane: lane, id: id} do
    :ok = Board.subscribe(lane)

    broadcast(lane, {:match_created, id, %{home: 0, away: 0}, self()})
    assert_receive {:match_added, ^id}

    broadcast(lane, {:goal, id, :home})
    assert_receive {:score_updated, ^id, %{home: 1, away: 0}}
  end

  test "reload/1 overwrites diverged rows from the true scores", %{lane: lane, id: id} do
    :ok = Matches.create_match(lane, id)
    :ok = Matches.score_goal(lane, id, :home)

    # Diverge this board: a creation and a forged goal the match never saw.
    broadcast(lane, {:match_created, id, %{home: 0, away: 0}, self()})
    broadcast(lane, {:goal, id, :away})
    sync(lane)
    assert {:ok, %{home: 0, away: 1}} = Board.fetch_score(lane, id)

    assert :ok = Board.reload(lane)
    assert {:ok, %{home: 1, away: 0}} = Board.fetch_score(lane, id)
  end

  @tag capture_log: true
  test "cursor_expired triggers a reload from the true scores", %{lane: lane, id: id} do
    :ok = Matches.create_match(lane, id)
    :ok = Matches.score_goal(lane, id, :home)

    broadcast(lane, {:match_created, id, %{home: 0, away: 0}, self()})
    broadcast(lane, {:goal, id, :away})
    sync(lane)
    assert {:ok, %{home: 0, away: 1}} = Board.fetch_score(lane, id)

    :ok = Board.subscribe(lane)
    broadcast(lane, {:cursor_expired, :peer@nohost})

    assert_receive :board_reloaded
    assert {:ok, %{home: 1, away: 0}} = Board.fetch_score(lane, id)
  end

  test "a restarted board rebuilds from the true scores", %{lane: lane, id: id} do
    :ok = Matches.create_match(lane, id)
    :ok = Matches.score_goal(lane, id, :home)

    board = Lane.board(lane)

    assert_eventually(fn -> assert {:ok, %{home: 1, away: 0}} = Board.fetch_score(lane, id) end)

    old = Process.whereis(board)
    ref = Process.monitor(old)
    Process.exit(old, :kill)
    assert_receive {:DOWN, ^ref, :process, ^old, :killed}

    assert_eventually(fn ->
      new = Process.whereis(board)
      assert is_pid(new) and new != old
      assert {:ok, %{home: 1, away: 0}} = Board.fetch_score(lane, id)
    end)
  end

  test "removes a match row when its monitored process dies", %{lane: lane, id: id} do
    :ok = Board.subscribe(lane)

    match = spawn(fn -> Process.sleep(:infinity) end)
    broadcast(lane, {:match_created, id, %{home: 0, away: 0}, match})
    assert_receive {:match_added, ^id}
    assert {:ok, %{home: 0, away: 0}} = Board.fetch_score(lane, id)

    Process.exit(match, :kill)

    assert_receive {:match_removed, ^id}
    assert :error = Board.fetch_score(lane, id)
  end

  test "fetch_score/2 returns :error for unknown ids", %{lane: lane, id: id} do
    assert :error = Board.fetch_score(lane, id)
  end

  test "a blipped board freezes and catches up on reload", %{lane: lane, id: id} do
    broadcast(lane, {:match_created, id, %{home: 0, away: 0}, self()})
    sync(lane)
    assert {:ok, %{home: 0, away: 0}} = Board.fetch_score(lane, id)

    # Offline: the truth advances in the DB, but events are dropped.
    Blip.on(lane)
    on_exit(fn -> Blip.off(lane) end)
    :ok = DB.write(lane, id, %{home: 3, away: 0})
    broadcast(lane, {:goal, id, :home})
    sync(lane)
    assert {:ok, %{home: 0, away: 0}} = Board.fetch_score(lane, id)

    # Back online: reload catches the board up to the truth.
    Blip.off(lane)
    assert :ok = Board.reload(lane)
    assert {:ok, %{home: 3, away: 0}} = Board.fetch_score(lane, id)
  end
end
