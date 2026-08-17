defmodule ScoreBoard.Matches do
  @moduledoc """
  Public API for the cluster-wide match processes.

  Each match runs as a single `ScoreBoard.Match` process somewhere in the
  cluster - the source of truth for its score - placed and supervised by
  Horde. All access goes through the Horde registry, so callers never care
  which node owns a match.

  ## Examples

      iex> ScoreBoard.Matches.create_match("POL-GER")
      :ok
      iex> ScoreBoard.Matches.score_goal("POL-GER", :home)
      :ok
      iex> ScoreBoard.Matches.score("POL-GER")
      {:ok, %{home: 1, away: 0}}
  """

  require Logger

  alias ScoreBoard.DB
  alias ScoreBoard.Match

  @registry ScoreBoard.MatchRegistry
  @supervisor ScoreBoard.MatchSupervisor

  # The fixtures a node can claim at startup. Each node takes one; a name
  # already taken by a peer is skipped, so N nodes host N distinct matches.
  @match_pool ~w(
    POL-GER ESP-FRA BRA-ARG ENG-ITA NED-POR BEL-CRO URU-COL MEX-USA JPN-KOR
    SEN-MAR SUI-SWE DEN-NOR AUT-CZE SCO-WAL GRE-TUR UKR-SRB NGA-GHA CHI-PER
    ECU-PAR CAN-AUS
  )

  @type match_id :: String.t()

  @doc """
  Starts a match process somewhere in the cluster.

  Idempotence is enforced by the registry: a second create for the same id
  fails, regardless of which node it runs on.
  """
  @spec create_match(match_id()) :: :ok | {:error, :already_exists}
  def create_match(id) when is_binary(id), do: create_match(id, :erlang.phash2(id))

  @doc """
  Starts a match with an explicit placement ordinal.

  The `index` drives node placement via `ScoreBoard.RoundRobinDistribution`
  (0..n-1 spreads one-per-node across n nodes); it has no effect on the
  match's behaviour.
  """
  @spec create_match(match_id(), non_neg_integer()) :: :ok | {:error, :already_exists}
  def create_match(id, index) when is_binary(id) and is_integer(index) do
    seed_score(id) |> dbg()

    case Horde.DynamicSupervisor.start_child(@supervisor, {Match, {id, index}}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> {:error, :already_exists}
      :ignore -> {:error, :already_exists}
    end
  end

  # Match.init reads its score from the DB and crashes on a missing row, so
  # a brand-new match needs its 0:0 in place before it starts. Seed only
  # when absent: a re-create (peer node or earlier boot) must not clobber a
  # score already recorded.
  @spec seed_score(match_id()) :: :ok | :error
  defp seed_score(id) do
    case DB.read(id) do
      :error -> DB.write(id, %{home: 0, away: 0})
      {:ok, _score} -> :ok
    end
  end

  @doc "Lists the ids of all matches known to the cluster."
  @spec list_matches() :: [match_id()]
  def list_matches do
    Horde.Registry.select(@registry, [{{{:match, :"$1"}, :_, :_}, [], [:"$1"]}])
  end

  @doc """
  Claims this node's fixture from `@match_pool` and places it on this node.

  Deterministic: the node at ordinal `i` (its slot among the sorted members)
  takes `@match_pool` entry `i`, which `RoundRobinDistribution` also maps back
  to this node. Returns `{:error, :pool_exhausted}` (and logs) when there are
  more nodes than fixtures.
  """
  @spec claim_one() :: {:ok, match_id()} | {:error, :pool_exhausted}
  def claim_one do
    index = node_ordinal()

    case Enum.at(@match_pool, index) do
      nil ->
        Logger.warning("No fixture for node ordinal #{index}; pool of #{length(@match_pool)} exhausted")
        {:error, :pool_exhausted}

      id ->
        # :ok, or a boot-race :already_exists, both leave this slot's match up.
        _ = create_match(id, index)
        {:ok, id}
    end
  end

  # This node's slot among the sorted members. RoundRobinDistribution maps
  # that ordinal back to this same node, so the claimed match runs locally.
  defp node_ordinal do
    [node() | Node.list()]
    |> Enum.sort()
    |> Enum.find_index(&(&1 == node()))
  end

  @doc "Scores a goal on the match process, wherever it runs."
  @spec score_goal(match_id(), Match.team()) :: :ok | {:error, :match_not_found}
  def score_goal(id, team) do
    GenServer.call(via(id), {:goal, team})
  catch
    :exit, {:noproc, _} -> {:error, :match_not_found}
  end

  @doc """
  The true score, read from the match process itself (the source of
  truth) - as opposed to a board's derived copy.
  """
  @spec score(match_id()) :: {:ok, Match.score()} | {:error, :match_not_found}
  def score(id) do
    GenServer.call(via(id), :score)
  catch
    :exit, {:noproc, _} -> {:error, :match_not_found}
  end

  @doc "The node currently running the match process."
  @spec owner_node(match_id()) :: {:ok, node()} | {:error, :match_not_found}
  def owner_node(id) do
    case Horde.Registry.lookup(@registry, {:match, id}) do
      [{pid, _value}] -> {:ok, node(pid)}
      [] -> {:error, :match_not_found}
    end
  end

  @doc false
  @spec via(match_id()) :: {:via, module(), {module(), {:match, match_id()}}}
  def via(id) do
    {:via, Horde.Registry, {@registry, {:match, id}}}
  end
end
