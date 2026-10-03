defmodule ScoreBoard.StatsStoreTest do
  use ExUnit.Case, async: true

  alias ScoreBoard.StatsStore

  @snapshot %{
    visits: 7,
    online: 2,
    peak_online: 3,
    rejected: 1,
    lanes: %{total: 2, taken: 2, free: 0}
  }

  describe "without a repo" do
    test "persistence is reported as off" do
      refute StatsStore.enabled?()
    end

    test "recording a sample is a no-op" do
      assert StatsStore.record(@snapshot) == :ok
    end

    test "there is no history and no totals to resume from" do
      assert StatsStore.history(10) == []
      assert StatsStore.last_totals() == %{visits: 0, rejected: 0}
    end
  end
end
