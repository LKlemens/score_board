defmodule ScoreBoard.BoardTest do
  # Each test runs its own board on its own topic, so tests never share
  # board state — that is what makes async safe here. Efx resolves the
  # Helper bindings by walking $ancestors, so both this process and the
  # board started under the test supervisor see the per-test values.
  use EfxCase, async: true

  import ScoreBoard.TestHelpers

  alias ScoreBoard.Board
  alias ScoreBoard.Board.Helper
  alias ScoreBoard.Matches

  setup %{test: test} do
    board = :"board_#{test}"
    topic = "#{test}:events"
    bind(&Helper.name/0, fn -> board end)
    bind(&Helper.topic/0, fn -> topic end)
    start_supervised!(Board)
    {:ok, id: Atom.to_string(test), board: board}
  end

  # Broadcast puts the event in the board's mailbox before returning, and a
  # call is processed strictly after it — after this, ETS is up to date.
  defp sync(board), do: :sys.get_state(board)

  defp broadcast(event) do
    Phoenix.PubSub.broadcast(ScoreBoard.PubSub, Helper.topic(), event)
  end

  test "derives rows from match_created and goal events", %{id: id, board: board} do
    broadcast({:match_created, id})
    broadcast({:goal, id, :home})
    sync(board)

    assert {:ok, %{home: 1, away: 0}} = Board.fetch_score(id)
    assert %{home: 1, away: 0} = Map.fetch!(Board.scores(), id)
  end

  @tag capture_log: true
  test "drops a goal for an unknown match with no reachable match process",
       %{id: id, board: board} do
    :ok = Board.subscribe()

    broadcast({:goal, id, :away})
    sync(board)

    # No fabricated row: the board stays consistent and retries the
    # recovery on the next goal.
    assert :error = Board.fetch_score(id)
    refute_receive {:match_added, ^id}
    refute_receive {:score_updated, ^id, _}
  end

  test "goal for an unknown match recovers the full true score", %{id: id, board: board} do
    :ok = Matches.create_match(id)
    :ok = Matches.score_goal(id, :home)
    :ok = Matches.score_goal(id, :home)

    # This board saw none of the above (it listens on its own topic); the
    # next goal forces it to recover the true score, not count from zero.
    broadcast({:goal, id, :away})
    sync(board)

    assert {:ok, %{home: 2, away: 0}} = Board.fetch_score(id)
  end

  test "notifies local subscribers after each applied event", %{id: id} do
    :ok = Board.subscribe()

    broadcast({:match_created, id})
    assert_receive {:match_added, ^id}

    broadcast({:goal, id, :home})
    assert_receive {:score_updated, ^id, %{home: 1, away: 0}}
  end

  test "reload/0 overwrites diverged rows from the true scores", %{id: id, board: board} do
    :ok = Matches.create_match(id)
    :ok = Matches.score_goal(id, :home)

    # Diverge this board: a creation and a forged goal the match never saw.
    broadcast({:match_created, id})
    broadcast({:goal, id, :away})
    sync(board)
    assert {:ok, %{home: 0, away: 1}} = Board.fetch_score(id)

    assert :ok = Board.reload()
    assert {:ok, %{home: 1, away: 0}} = Board.fetch_score(id)
  end

  test "a restarted board rebuilds from the true scores", %{id: id, board: board} do
    :ok = Matches.create_match(id)
    :ok = Matches.score_goal(id, :home)

    # Killing the board wipes its ETS table; the restarted board catches up
    # via the reload it runs in handle_continue. The kill is asynchronous —
    # wait for the DOWN before polling, or we would read the old table and
    # let the test end mid-restart.
    old = Process.whereis(board)
    ref = Process.monitor(old)
    Process.exit(old, :kill)
    assert_receive {:DOWN, ^ref, :process, ^old, :killed}

    assert_eventually(fn ->
      new = Process.whereis(board)
      assert is_pid(new) and new != old
      assert {:ok, %{home: 1, away: 0}} = Board.fetch_score(id)
    end)
  end

  test "fetch_score/1 returns :error for unknown ids", %{id: id} do
    assert :error = Board.fetch_score(id)
  end
end
