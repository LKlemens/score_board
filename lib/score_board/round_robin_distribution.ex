defmodule ScoreBoard.RoundRobinDistribution do
  @moduledoc """
  Places each match by its creation ordinal rather than a hash, so N
  matches spread one-per-node across N alive members (round-robin beyond
  that). Recomputed on every membership change, so failover and rebalance
  still work.

  The ordinal rides in the child spec's `start` args - the only part Horde
  preserves through its `:id` randomization, so it survives placement.
  """
  @behaviour Horde.DistributionStrategy

  alias Horde.DynamicSupervisor.Member

  @impl Horde.DistributionStrategy
  @spec choose_node(Supervisor.child_spec(), [Member.t()]) ::
          {:ok, Member.t()} | {:error, :no_alive_nodes}
  def choose_node(child_spec, members) do
    members
    |> Enum.filter(&match?(%Member{status: :alive}, &1))
    # member.name is {supervisor_name, node}, identical across the synced
    # cluster - so every node derives the same ordinal-to-node mapping.
    |> Enum.sort_by(& &1.name)
    |> case do
      [] -> {:error, :no_alive_nodes}
      alive -> {:ok, Enum.at(alive, rem(ordinal(child_spec), length(alive)))}
    end
  end

  @impl Horde.DistributionStrategy
  @spec has_quorum?([Member.t()]) :: boolean()
  def has_quorum?(_members), do: true

  @spec ordinal(Supervisor.child_spec()) :: non_neg_integer()
  defp ordinal(%{start: {_module, _fun, [{_lane, _id, index}]}}), do: index
end
