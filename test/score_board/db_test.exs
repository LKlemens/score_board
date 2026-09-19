defmodule ScoreBoard.DBTest do
  # Each test gets its own lane, so replicas never share state - async safe.
  use ExUnit.Case, async: true

  import ScoreBoard.TestHelpers

  alias ScoreBoard.DB
  alias ScoreBoard.Lane

  setup %{test: test} do
    lane = start_lane(test)
    {:ok, lane: lane, id: Atom.to_string(test)}
  end

  test "read/write/all round-trip", %{lane: lane, id: id} do
    assert :error = DB.read(lane, id)

    assert :ok = DB.write(lane, id, %{home: 3, away: 1})
    assert {:ok, %{home: 3, away: 1}} = DB.read(lane, id)
    assert %{^id => %{home: 3, away: 1}} = DB.all(lane)

    assert :ok = DB.write(lane, id, %{home: 3, away: 2})
    assert {:ok, %{home: 3, away: 2}} = DB.read(lane, id)
  end

  test "a replicated write from a peer merges componentwise-max", %{lane: lane, id: id} do
    GenServer.cast(Lane.db(lane), {:replicate, id, %{home: 2, away: 0}})
    GenServer.cast(Lane.db(lane), {:replicate, id, %{home: 1, away: 5}})

    assert_eventually(fn -> assert DB.read(lane, id) == {:ok, %{home: 2, away: 5}} end)
  end

  test "merge_all folds a peer's whole state in by max", %{lane: lane, id: id} do
    :ok = DB.write(lane, id, %{home: 4, away: 1})
    GenServer.cast(Lane.db(lane), {:merge_all, %{id => %{home: 2, away: 3}}})

    assert_eventually(fn -> assert DB.read(lane, id) == {:ok, %{home: 4, away: 3}} end)
  end
end
