defmodule ScoreBoard.BlipTest do
  # The blip flag is app-wide (echo_pubsub's application env), so this
  # suite is serialized.
  use ExUnit.Case, async: false

  alias ScoreBoard.Blip

  setup do
    on_exit(fn -> Blip.off() end)
    :ok
  end

  test "toggles echo_pubsub's fault injection and defaults to off" do
    refute Blip.enabled?()

    assert :ok = Blip.on()
    assert Blip.enabled?()
    assert Application.get_env(:echo_pubsub, :fault_injection) == :error

    assert :ok = Blip.off()
    refute Blip.enabled?()
    assert Application.get_env(:echo_pubsub, :fault_injection) == :ok
  end
end
