defmodule ScoreBoard.StatsTest do
  # Shares the app-wide Stats server and lane pool, so it runs serially.
  use ExUnit.Case, async: false

  import ScoreBoard.TestHelpers

  alias ScoreBoard.Stats

  describe "visit/1" do
    test "counts a visitor and keeps them online while their process lives" do
      before = Stats.snapshot()
      {:ok, pid} = Agent.start_link(fn -> :visitor end)

      Stats.visit(pid)

      assert_eventually(fn ->
        now = Stats.snapshot()
        assert now.visits == before.visits + 1
        assert now.online == before.online + 1
      end)
    end

    test "the same process visiting twice is one visitor" do
      before = Stats.snapshot()
      {:ok, pid} = Agent.start_link(fn -> :visitor end)

      Stats.visit(pid)
      Stats.visit(pid)

      assert_eventually(fn -> assert Stats.snapshot().visits == before.visits + 1 end)
    end

    test "a visitor who leaves drops off the online count" do
      {:ok, pid} = Agent.start_link(fn -> :visitor end)
      Stats.visit(pid)
      assert_eventually(fn -> assert Stats.snapshot().online >= 1 end)

      before = Stats.snapshot()
      Agent.stop(pid)

      assert_eventually(fn -> assert Stats.snapshot().online == before.online - 1 end)
    end

    test "peak online never goes down" do
      {:ok, pid} = Agent.start_link(fn -> :visitor end)
      Stats.visit(pid)
      assert_eventually(fn -> assert Stats.snapshot().peak_online >= 1 end)

      peak = Stats.snapshot().peak_online
      Agent.stop(pid)

      assert_eventually(fn -> assert Stats.snapshot().peak_online == peak end)
    end
  end

  describe "rejected/0" do
    test "counts a visitor who found the pool full" do
      before = Stats.snapshot()

      Stats.rejected()

      assert_eventually(fn -> assert Stats.snapshot().rejected == before.rejected + 1 end)
    end
  end

  describe "snapshot/0" do
    test "reports the lane pool alongside the counters" do
      snapshot = Stats.snapshot()

      assert %{lanes: %{total: total, taken: taken, free: free}} = snapshot
      assert total == taken + free
      assert is_integer(snapshot.visits)
      assert is_integer(snapshot.online)
    end
  end
end
