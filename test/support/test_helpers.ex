defmodule ScoreBoard.TestHelpers do
  @moduledoc """
  Shared polling helpers for asserting on eventually-consistent state
  (Horde registry sync, PubSub-driven ETS updates).
  """

  @doc """
  Retries `fun` on assertion errors and re-raises the real failure on
  timeout, so the test report shows which assertion never converged.
  """
  @spec assert_eventually((-> any()), timeout()) :: any()
  def assert_eventually(fun, timeout \\ 1_000) do
    do_assert_eventually(fun, System.monotonic_time(:millisecond), timeout)
  end

  defp do_assert_eventually(fun, started_at, timeout) do
    fun.()
  rescue
    error in ExUnit.AssertionError ->
      if System.monotonic_time(:millisecond) - started_at < timeout do
        Process.sleep(10)
        do_assert_eventually(fun, started_at, timeout)
      else
        reraise error, __STACKTRACE__
      end
  end
end
