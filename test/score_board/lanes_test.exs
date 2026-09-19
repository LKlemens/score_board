defmodule ScoreBoard.LanesTest do
  # Shares the app-wide lane pool, so it runs serially and releases what it takes.
  use ExUnit.Case, async: false

  alias ScoreBoard.Blip
  alias ScoreBoard.Lane
  alias ScoreBoard.Lanes

  setup %{test: test} do
    tenant = Atom.to_string(test)
    on_exit(fn -> Lanes.release(tenant) end)
    {:ok, tenant: tenant}
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
    tenants = for i <- 1..(Lane.count() + 1), do: "drainer-#{i}"
    on_exit(fn -> Enum.each(tenants, &Lanes.release/1) end)

    results = Enum.map(tenants, &Lanes.assign/1)
    assert Enum.count(results, &match?({:ok, _}, &1)) == Lane.count()
    assert List.last(results) == {:error, :pool_exhausted}

    :ok = Lanes.release(hd(tenants))
    assert {:ok, _id} = Lanes.assign(List.last(tenants))
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
