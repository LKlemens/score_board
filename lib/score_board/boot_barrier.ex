defmodule ScoreBoard.BootBarrier do
  @moduledoc """
  Supervision-tree ordering barrier: `start_link/1` blocks for `ms` then
  returns `:ignore`, so later children start only once the delay elapses.
  """

  @spec start_link(non_neg_integer()) :: :ignore
  def start_link(ms) do
    Process.sleep(ms)
    :ignore
  end

  @spec child_spec(non_neg_integer()) :: Supervisor.child_spec()
  def child_spec(ms) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [ms]}, restart: :temporary}
  end
end
