defmodule ScoreBoard.TestHelpers do
  @moduledoc """
  Shared helpers: polling for eventually-consistent state, and starting an
  isolated tenant lane so async tests never share DB/board/event-bus state.
  """

  import ExUnit.Callbacks, only: [start_supervised!: 1]

  alias ScoreBoard.Lane

  @doc """
  Starts an isolated lane (its own event bus, DB replica, and board) under the
  test supervisor and returns its id. Each test gets a unique lane, so boards
  and scores never collide even when tests run async.
  """
  @spec start_lane(term()) :: Lane.id()
  def start_lane(id) do
    start_supervised!(
      Supervisor.child_spec(
        {Phoenix.PubSub,
         name: Lane.pubsub(id), adapter: EchoPubSub, pool_size: 1, buffer_size: Lane.buffer_size()},
        id: {:test_bus, id}
      )
    )

    start_supervised!(Supervisor.child_spec({ScoreBoard.DB, id}, id: {:test_db, id}))
    start_supervised!(Supervisor.child_spec({ScoreBoard.Board, id}, id: {:test_board, id}))
    id
  end

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
