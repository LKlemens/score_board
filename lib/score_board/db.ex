defmodule ScoreBoard.DB do
  @moduledoc """
  A stand-in for a database: one process in the whole cluster holding the
  latest score per match - read and write, nothing else. Matches write
  through on every goal and read on (re)start, so a restarted or moved
  match keeps its score without any peer coordination.

  Runs under its own Horde supervisor (`ScoreBoard.DBSupervisor`), isolated
  from the matches: when its host node dies, Horde restarts it on a
  survivor - empty, since it is in-memory
  only. Matches then fall back to the boards' derived state on restore and
  refill the DB with their next goals. If two copies ever race up before
  the registries sync, the losing copy max-merges its data into the winner
  and stops.
  """
  use GenServer, restart: :transient

  alias ScoreBoard.Match
  alias ScoreBoard.Matches

  @name {:via, Horde.Registry, {ScoreBoard.MatchRegistry, :db}}
  @supervisor ScoreBoard.DBSupervisor

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: @name)
  end

  @doc """
  Starts the DB somewhere in the cluster if it is not running yet.

  Called by every node at boot; the registry makes it idempotent.
  """
  @spec ensure_started() :: :ok
  def ensure_started do
    # A just-joined node may not have synced an existing registration yet
    # (Horde's registry is eventually consistent); starting a duplicate
    # would let fresh boards reload from an empty copy, so give the
    # registry a moment first.
    if Node.list() != [], do: await_registration(20)

    if alive?() do
      :ok
    else
      case Horde.DynamicSupervisor.start_child(@supervisor, __MODULE__) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        :ignore -> :ok
      end
    end
  end

  @doc "Whether a DB process is currently visible in the registry."
  @spec alive?() :: boolean()
  def alive?, do: is_pid(GenServer.whereis(@name))

  @doc "The stored score for a match."
  @spec read(Matches.match_id()) :: {:ok, Match.score()} | :error
  def read(id), do: safe_call({:read, id}, :error)

  @doc "Stores the latest score for a match."
  @spec write(Matches.match_id(), Match.score()) :: :ok | :error
  def write(id, score), do: safe_call({:write, id, score}, :error)

  @doc "All stored scores, keyed by match id."
  @spec all() :: %{Matches.match_id() => Match.score()}
  def all, do: safe_call(:all, %{})

  @impl GenServer
  def init(:ok) do
    # Trap exits so a Horde registry name conflict arrives as a message.
    Process.flag(:trap_exit, true)
    {:ok, %{}}
  end

  # Reads and writes both go through the GenServer so callers on any node
  # reach the single owner via its registered name. A real DB would let
  # reads bypass the process (e.g. an ETS table with read_concurrency), but
  # this in-memory stand-in stays a plain serialized map - there is no
  # point optimizing it for the sake of keeping the example simple.
  @impl GenServer
  def handle_call({:read, id}, _from, scores) do
    {:reply, Map.fetch(scores, id), scores}
  end

  def handle_call({:write, id, score}, _from, scores) do
    {:reply, :ok, Map.put(scores, id, score)}
  end

  def handle_call(:all, _from, scores) do
    {:reply, scores, scores}
  end

  @impl GenServer
  def handle_cast({:merge, other}, scores) do
    {:noreply, Map.merge(scores, other, fn _id, a, b -> max_score(a, b) end)}
  end

  @impl GenServer
  def handle_info({:EXIT, _pid, {:name_conflict, _key_value, _registry, winner}}, scores) do
    # A duplicate DB registered elsewhere and this copy lost: hand over
    # everything (max-merged there) and stop cleanly.
    GenServer.cast(winner, {:merge, scores})
    {:stop, :normal, scores}
  end

  def handle_info({:EXIT, _pid, reason}, scores) do
    {:stop, reason, scores}
  end

  # Goal counters only ever increment, so componentwise max cannot lose
  # goals, whichever copy was further ahead.
  defp max_score(a, b), do: %{home: max(a.home, b.home), away: max(a.away, b.away)}

  defp await_registration(0), do: :ok

  defp await_registration(retries) do
    if alive?() do
      :ok
    else
      Process.sleep(150)
      await_registration(retries - 1)
    end
  end

  # The DB may briefly be down mid-failover; scoring must keep working, so
  # callers get a fallback instead of an exit.
  defp safe_call(request, fallback) do
    GenServer.call(@name, request)
  catch
    :exit, _reason -> fallback
  end
end
