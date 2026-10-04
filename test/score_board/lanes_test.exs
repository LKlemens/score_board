defmodule ScoreBoard.LanesTest do
  # Shares the app-wide lane pool, so it runs serially and releases what it takes.
  use ExUnit.Case, async: false

  import ScoreBoard.TestHelpers

  alias ScoreBoard.Blip
  alias ScoreBoard.Cluster
  alias ScoreBoard.Lane
  alias ScoreBoard.Lanes
  alias ScoreBoard.Matches

  setup %{test: test} do
    tenant = Atom.to_string(test)
    on_exit(fn -> Lanes.release(tenant) end)
    {:ok, tenant: tenant}
  end

  test "a lane's snapshot finds its producer (capacity is set)" do
    assert %{capacity: capacity} = Cluster.snapshot(hd(Lane.ids()))
    assert is_integer(capacity)
  end

  test "assigning a lane seeds one market per node", %{tenant: tenant} do
    {:ok, lane} = Lanes.assign(tenant)

    assert_eventually(fn -> assert Matches.list_matches(lane) != [] end)
  end

  test "assigns a lane and resolves it back", %{tenant: tenant} do
    assert {:ok, id} = Lanes.assign(tenant)
    assert {:ok, ^id} = Lanes.lane_for(tenant)
  end

  test "assigning the same tenant twice returns the same lane", %{tenant: tenant} do
    assert {:ok, id} = Lanes.assign(tenant)
    assert {:ok, ^id} = Lanes.assign(tenant)
  end

  test "different tenants get different lanes", %{tenant: tenant} do
    other = tenant <> "-2"
    on_exit(fn -> Lanes.release(other) end)

    assert {:ok, a} = Lanes.assign(tenant)
    assert {:ok, b} = Lanes.assign(other)
    assert a != b
  end

  test "a released lane returns to the pool", %{tenant: tenant} do
    assert {:ok, _id} = Lanes.assign(tenant)
    assert :ok = Lanes.release(tenant)
    assert :error = Lanes.lane_for(tenant)
  end

  test "an exhausted pool is rejected, and frees up again after release" do
    [first | _] = tenants = for i <- 1..(Lane.count() + 1), do: "drainer-#{i}"
    last = List.last(tenants)
    on_exit(fn -> Enum.each(tenants, &Lanes.release/1) end)

    results = Enum.map(tenants, &Lanes.assign/1)
    assert Enum.count(results, &match?({:ok, _}, &1)) == Lane.count()
    assert List.last(results) == {:error, :pool_exhausted}

    :ok = Lanes.release(first)
    assert {:ok, _id} = Lanes.assign(last)
  end

  describe "idle sweep" do
    setup do
      ttl = Application.get_env(:score_board, :lane_ttl_ms)
      on_exit(fn -> Application.put_env(:score_board, :lane_ttl_ms, ttl) end)
      :ok
    end

    test "a lane idle past the TTL goes back to the pool", %{tenant: tenant} do
      {:ok, id} = Lanes.assign(tenant)
      Application.put_env(:score_board, :lane_ttl_ms, 0)

      assert tenant in Lanes.sweep()
      assert :error = Lanes.lane_for(tenant)
      assert {:ok, ^id} = Lanes.assign(tenant)
    end

    test "touching a lane keeps it", %{tenant: tenant} do
      {:ok, id} = Lanes.assign(tenant)
      Application.put_env(:score_board, :lane_ttl_ms, :timer.minutes(5))
      Lanes.touch(tenant)

      assert Lanes.sweep() == []
      assert {:ok, ^id} = Lanes.lane_for(tenant)
    end

    test "the tenant hears that its lane expired", %{tenant: tenant} do
      {:ok, _id} = Lanes.assign(tenant)
      :ok = Phoenix.PubSub.subscribe(ScoreBoard.PubSub, Lanes.topic(tenant))
      Application.put_env(:score_board, :lane_ttl_ms, 0)

      Lanes.sweep()

      assert_receive :lane_expired, 1_000
    end

    test "a swept lane is wiped before it is handed on", %{tenant: tenant} do
      {:ok, id} = Lanes.assign(tenant)
      assert_eventually(fn -> assert Matches.list_matches(id) != [] end)
      [match | _] = Matches.list_matches(id)
      :ok = Matches.score_goal(id, match, :home)

      Application.put_env(:score_board, :lane_ttl_ms, 0)
      Lanes.sweep()

      # Horde drops registry entries asynchronously, so the list empties a beat
      # after terminate_child/2 returns.
      assert_eventually(fn ->
        assert Matches.list_matches(id) == []
        assert ScoreBoard.DB.all(id) == %{}
      end)
    end

    test "an untouched tenant is swept even if it never acted", %{tenant: tenant} do
      {:ok, _id} = Lanes.assign(tenant)
      Application.put_env(:score_board, :lane_ttl_ms, 0)

      assert tenant in Lanes.sweep()
    end
  end

  test "each lane runs its own event bus, faultable in isolation" do
    [one, two | _] = Lane.ids()

    assert is_pid(Process.whereis(Lane.pubsub(one)))
    assert is_pid(Process.whereis(Lane.pubsub(two)))

    Blip.on(one)
    on_exit(fn -> Blip.off(one) end)

    assert Blip.enabled?(one)
    refute Blip.enabled?(two)
  end
end
