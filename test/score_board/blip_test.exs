defmodule ScoreBoard.BlipTest do
  # The flag is keyed per lane, so distinct lanes never interfere - async safe.
  use ExUnit.Case, async: true

  alias ScoreBoard.Blip

  setup %{test: test} do
    on_exit(fn -> Blip.off(test) end)
    {:ok, lane: test}
  end

  test "toggles this lane's fault injection and defaults to off", %{lane: lane} do
    refute Blip.enabled?(lane)

    assert :ok = Blip.on(lane)
    assert Blip.enabled?(lane)

    assert :ok = Blip.off(lane)
    refute Blip.enabled?(lane)
  end

  test "one lane's blip does not affect another", %{lane: lane} do
    other = :"#{lane}-other"
    on_exit(fn -> Blip.off(other) end)

    assert :ok = Blip.on(lane)
    assert Blip.enabled?(lane)
    refute Blip.enabled?(other)
  end
end
