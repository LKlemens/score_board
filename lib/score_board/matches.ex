defmodule ScoreBoard.Matches do
  @moduledoc """
  Public API for the cluster-wide match processes.

  Each match runs as a single `ScoreBoard.Match` process somewhere in the
  cluster — the source of truth for its score — placed and supervised by
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

  alias ScoreBoard.Match

  @registry ScoreBoard.MatchRegistry
  @supervisor ScoreBoard.MatchSupervisor

  @type match_id :: String.t()

  @doc """
  Starts a match process somewhere in the cluster.

  Idempotence is enforced by the registry: a second create for the same id
  fails, regardless of which node it runs on.
  """
  @spec create_match(match_id()) :: :ok | {:error, :already_exists}
  def create_match(id) when is_binary(id) do
    case Horde.DynamicSupervisor.start_child(@supervisor, {Match, id}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> {:error, :already_exists}
      :ignore -> {:error, :already_exists}
    end
  end

  @doc "Lists the ids of all matches known to the cluster."
  @spec list_matches() :: [match_id()]
  def list_matches do
    Horde.Registry.select(@registry, [{{{:match, :"$1"}, :_, :_}, [], [:"$1"]}])
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
  truth) — as opposed to a board's derived copy.
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
