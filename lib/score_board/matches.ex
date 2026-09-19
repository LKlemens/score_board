defmodule ScoreBoard.Matches do
  @moduledoc """
  Public API for a lane's match processes.

  Each match runs as a single `ScoreBoard.Match` process somewhere in the
  cluster - the source of truth for its score - placed and supervised by a
  shared Horde registry/supervisor. Registry keys are prefixed with the lane,
  so matches of different lanes never collide even under the same id.

  ## Examples

      iex> ScoreBoard.Matches.create_match(1, "POL-GER")
      :ok
      iex> ScoreBoard.Matches.score_goal(1, "POL-GER", :home)
      :ok
      iex> ScoreBoard.Matches.score(1, "POL-GER")
      {:ok, %{home: 1, away: 0}}
  """

  alias ScoreBoard.DB
  alias ScoreBoard.Lane
  alias ScoreBoard.Match

  @registry ScoreBoard.MatchRegistry
  @supervisor ScoreBoard.MatchSupervisor

  @type match_id :: String.t()

  @doc """
  Starts a match process for `lane` somewhere in the cluster.

  Idempotence is enforced by the registry: a second create for the same
  `{lane, id}` fails, regardless of which node it runs on.
  """
  @spec create_match(Lane.id(), match_id()) :: :ok | {:error, :already_exists}
  def create_match(lane, id) when is_binary(id), do: create_match(lane, id, :erlang.phash2(id))

  @doc """
  Starts a match with an explicit placement ordinal.

  The `index` drives node placement via `ScoreBoard.RoundRobinDistribution`
  (0..n-1 spreads one-per-node across n nodes); it has no effect on the
  match's behaviour.
  """
  @spec create_match(Lane.id(), match_id(), non_neg_integer()) :: :ok | {:error, :already_exists}
  def create_match(lane, id, index) when is_binary(id) and is_integer(index) do
    seed_score(lane, id)

    case Horde.DynamicSupervisor.start_child(@supervisor, {Match, {lane, id, index}}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> {:error, :already_exists}
      :ignore -> {:error, :already_exists}
    end
  end

  # Match reads its score from the DB on start, so a brand-new match needs its
  # 0:0 in place first. Seed only when absent: a re-create (peer node or
  # earlier boot) must not clobber a score already recorded.
  @spec seed_score(Lane.id(), match_id()) :: :ok
  defp seed_score(lane, id) do
    case DB.read(lane, id) do
      :error -> DB.write(lane, id, %{home: 0, away: 0})
      {:ok, _score} -> :ok
    end
  end

  @doc "Lists the ids of all matches in `lane`."
  @spec list_matches(Lane.id()) :: [match_id()]
  def list_matches(lane) do
    Horde.Registry.select(@registry, [{{{:match, lane, :"$1"}, :_, :_}, [], [:"$1"]}])
  end

  @doc "Scores a goal on the match process, wherever it runs."
  @spec score_goal(Lane.id(), match_id(), Match.team()) :: :ok | {:error, :match_not_found}
  def score_goal(lane, id, team) do
    GenServer.call(via(lane, id), {:goal, team})
  catch
    :exit, {:noproc, _} -> {:error, :match_not_found}
  end

  @doc """
  The true score, read from the match process itself (the source of
  truth) - as opposed to a board's derived copy.
  """
  @spec score(Lane.id(), match_id()) :: {:ok, Match.score()} | {:error, :match_not_found}
  def score(lane, id) do
    GenServer.call(via(lane, id), :score)
  catch
    :exit, {:noproc, _} -> {:error, :match_not_found}
  end

  @doc "The node currently running the match process."
  @spec owner_node(Lane.id(), match_id()) :: {:ok, node()} | {:error, :match_not_found}
  def owner_node(lane, id) do
    case Horde.Registry.lookup(@registry, {:match, lane, id}) do
      [{pid, _value}] -> {:ok, node(pid)}
      [] -> {:error, :match_not_found}
    end
  end

  @doc false
  @spec via(Lane.id(), match_id()) ::
          {:via, module(), {module(), {:match, Lane.id(), match_id()}}}
  def via(lane, id) do
    {:via, Horde.Registry, {@registry, {:match, lane, id}}}
  end
end
