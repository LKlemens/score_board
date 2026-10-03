defmodule ScoreBoard.StatsTest do
  # Shares the app-wide Stats server and lane pool, so it runs serially.
  use ExUnit.Case, async: false

  import ScoreBoard.TestHelpers

  alias ScoreBoard.Stats

  setup %{test: test} do
    {:ok, tenant: Atom.to_string(test)}
  end

  defp visitor do
    {:ok, pid} = Agent.start(fn -> :visitor end)
    on_exit(fn -> if Process.alive?(pid), do: Agent.stop(pid) end)
    pid
  end

  describe "visit/2" do
    test "counts a visitor and keeps them online while their process lives", %{tenant: tenant} do
      before = Stats.snapshot()

      Stats.visit(tenant, visitor())

      assert_eventually(fn ->
        now = Stats.snapshot()
        assert now.visits == before.visits + 1
        assert now.online == before.online + 1
      end)
    end

    test "the same process visiting twice is one visitor", %{tenant: tenant} do
      before = Stats.snapshot()
      pid = visitor()

      Stats.visit(tenant, pid)
      Stats.visit(tenant, pid)

      assert_eventually(fn -> assert Stats.snapshot().visits == before.visits + 1 end)
    end

    test "a refresh is the same visitor, not a new one", %{tenant: tenant} do
      before = Stats.snapshot()

      # A reload means a fresh LiveView process for the same browser cookie.
      old_tab = visitor()
      Stats.visit(tenant, old_tab)
      assert_eventually(fn -> assert Stats.snapshot().visits == before.visits + 1 end)

      Agent.stop(old_tab)
      Stats.visit(tenant, visitor())

      assert_eventually(fn ->
        now = Stats.snapshot()
        assert now.visits == before.visits + 1
        assert now.online == before.online + 1
      end)
    end

    test "two tabs of one browser are one person online", %{tenant: tenant} do
      before = Stats.snapshot()

      Stats.visit(tenant, visitor())
      Stats.visit(tenant, visitor())

      assert_eventually(fn ->
        now = Stats.snapshot()
        assert now.visits == before.visits + 1
        assert now.online == before.online + 1
      end)
    end

    test "two browsers are two visitors", %{tenant: tenant} do
      before = Stats.snapshot()

      Stats.visit(tenant, visitor())
      Stats.visit(tenant <> "-other", visitor())

      assert_eventually(fn ->
        now = Stats.snapshot()
        assert now.visits == before.visits + 2
        assert now.online == before.online + 2
      end)
    end

    test "a visitor who leaves drops off the online count", %{tenant: tenant} do
      pid = visitor()
      Stats.visit(tenant, pid)
      assert_eventually(fn -> assert Stats.snapshot().online >= 1 end)

      before = Stats.snapshot()
      Agent.stop(pid)

      assert_eventually(fn -> assert Stats.snapshot().online == before.online - 1 end)
    end

    test "one browser stays online until its last tab closes", %{tenant: tenant} do
      first = visitor()
      second = visitor()
      Stats.visit(tenant, first)
      Stats.visit(tenant, second)
      assert_eventually(fn -> assert Stats.snapshot().online >= 1 end)

      before = Stats.snapshot()
      Agent.stop(first)

      assert_eventually(fn -> assert Stats.snapshot().online == before.online end)

      Agent.stop(second)

      assert_eventually(fn -> assert Stats.snapshot().online == before.online - 1 end)
    end

    test "peak online never goes down", %{tenant: tenant} do
      pid = visitor()
      Stats.visit(tenant, pid)
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

  describe "serving?/0" do
    setup do
      original = Application.get_env(:score_board, ScoreBoardWeb.Endpoint)
      on_exit(fn -> Application.put_env(:score_board, ScoreBoardWeb.Endpoint, original) end)
      {:ok, original: original}
    end

    test "false for a headless board", %{original: original} do
      Application.put_env(
        :score_board,
        ScoreBoardWeb.Endpoint,
        Keyword.put(original, :server, false)
      )

      refute Stats.serving?()
    end

    test "true for the node whose endpoint listens", %{original: original} do
      Application.put_env(
        :score_board,
        ScoreBoardWeb.Endpoint,
        Keyword.put(original, :server, true)
      )

      assert Stats.serving?()
    end

    test "true under mix phx.server, which sets serve_endpoints instead", %{original: original} do
      Application.put_env(
        :score_board,
        ScoreBoardWeb.Endpoint,
        Keyword.delete(original, :server)
      )

      Application.put_env(:phoenix, :serve_endpoints, true)
      on_exit(fn -> Application.delete_env(:phoenix, :serve_endpoints) end)

      assert Stats.serving?()
    end
  end

  describe "digest_due?/3" do
    test "not before the configured hour" do
      refute Stats.digest_due?(nil, ~U[2026-10-03 07:59:00Z], 8)
    end

    test "due past the hour when nothing was ever sent" do
      assert Stats.digest_due?(nil, ~U[2026-10-03 08:00:00Z], 8)
    end

    test "not due again on a day already recorded" do
      today = %ScoreBoard.StatsDigest{sent_on: ~D[2026-10-03]}

      refute Stats.digest_due?(today, ~U[2026-10-03 20:00:00Z], 8)
    end

    test "due again the next day" do
      yesterday = %ScoreBoard.StatsDigest{sent_on: ~D[2026-10-02]}

      assert Stats.digest_due?(yesterday, ~U[2026-10-03 09:00:00Z], 8)
    end
  end

  describe "digest_changed?/2" do
    @snapshot %{
      visits: 10,
      online: 1,
      peak_online: 4,
      rejected: 2,
      lanes: %{total: 2, taken: 1, free: 1}
    }

    test "nothing to report on a first digest with no activity" do
      refute Stats.digest_changed?(nil, %{@snapshot | visits: 0, rejected: 0})
    end

    test "a first digest with visitors is worth sending" do
      assert Stats.digest_changed?(nil, @snapshot)
    end

    test "identical numbers are not worth sending" do
      last = %ScoreBoard.StatsDigest{visits: 10, rejected: 2, peak_online: 4}

      refute Stats.digest_changed?(last, @snapshot)
    end

    test "any moved counter is worth sending" do
      for field <- [:visits, :rejected, :peak_online] do
        last =
          %ScoreBoard.StatsDigest{visits: 10, rejected: 2, peak_online: 4}
          |> Map.update!(field, &(&1 - 1))

        assert Stats.digest_changed?(last, @snapshot), "expected a change in #{field} to count"
      end
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
