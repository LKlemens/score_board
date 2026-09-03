defmodule ScoreBoard.DBTest do
  # One replica per node; this suite is single-node, so it exercises the
  # local merge handlers directly. Ids are test-scoped for concurrency.
  use ExUnit.Case, async: true

  import ScoreBoard.TestHelpers

  alias ScoreBoard.DB

  setup %{test: test} do
    {:ok, id: Atom.to_string(test)}
  end

  test "read/write/all round-trip", %{id: id} do
    assert :error = DB.read(id)

    assert :ok = DB.write(id, %{home: 3, away: 1})
    assert {:ok, %{home: 3, away: 1}} = DB.read(id)
    assert %{^id => %{home: 3, away: 1}} = DB.all()

    assert :ok = DB.write(id, %{home: 3, away: 2})
    assert {:ok, %{home: 3, away: 2}} = DB.read(id)
  end

  test "a replicated write from a peer merges componentwise-max", %{id: id} do
    GenServer.cast(DB, {:replicate, id, %{home: 2, away: 0}})
    GenServer.cast(DB, {:replicate, id, %{home: 1, away: 5}})

    assert_eventually(fn -> assert DB.read(id) == {:ok, %{home: 2, away: 5}} end)
  end

  test "merge_all folds a peer's whole state in by max", %{id: id} do
    :ok = DB.write(id, %{home: 4, away: 1})
    GenServer.cast(DB, {:merge_all, %{id => %{home: 2, away: 3}}})

    assert_eventually(fn -> assert DB.read(id) == {:ok, %{home: 4, away: 3}} end)
  end
end
