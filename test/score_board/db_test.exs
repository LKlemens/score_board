defmodule ScoreBoard.DBTest do
  # One DB in the cluster - tests share it, so ids are test-scoped.
  use ExUnit.Case, async: true

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
end
