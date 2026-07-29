defmodule ScoreBoard.Board do
  @moduledoc """
  Per-node derived scoreboard for all matches.

  Subscribes to match events and folds them into a public-read ETS table.
  This is deliberately a cache: a missed event leaves this node's board
  permanently wrong — the failure mode the demo showcases. `reload/0`
  rebuilds the table from the authoritative match processes.

  Writes serialize through the GenServer; reads go straight to ETS.
  """
  use GenServer

  require Logger

  alias ScoreBoard.Match
  alias ScoreBoard.Matches

  @table __MODULE__
  @updates_topic "board:updates"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc "All matches this node knows about, keyed by match id."
  @spec scores() :: %{Matches.match_id() => Match.score()}
  def scores do
    @table
    |> :ets.tab2list()
    |> Map.new(fn {id, home, away} -> {id, %{home: home, away: away}} end)
  end

  @doc """
  This node's derived score for one match.

  Safe to call even before the table exists (a Horde-restarted match uses
  it during startup to restore its authoritative score).
  """
  @spec fetch_score(Matches.match_id()) :: {:ok, Match.score()} | :error
  def fetch_score(id) do
    case :ets.lookup(@table, id) do
      [{^id, home, away}] -> {:ok, %{home: home, away: away}}
      [] -> :error
    end
  rescue
    ArgumentError -> :error
  end

  @doc """
  Subscribes the caller to this node's board updates: `{:match_added, id}`,
  `{:score_updated, id, score}`, and `:board_reloaded`.

  Emitted after ETS is written, so unlike subscribing to raw match events
  there is no window where a reader sees a stale board with no further
  update coming.
  """
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    Phoenix.PubSub.subscribe(ScoreBoard.PubSub, @updates_topic)
  end

  @doc """
  Rebuilds the derived table from the authoritative match processes — the
  recovery path for a board that knows it missed events.
  """
  @spec reload() :: :ok
  def reload do
    GenServer.call(__MODULE__, :reload)
  end

  @impl GenServer
  def init(:ok) do
    :ets.new(@table, [:named_table, :protected, read_concurrency: true])
    :ok = Phoenix.PubSub.subscribe(ScoreBoard.PubSub, Match.topic())
    # Catch up on matches that existed before this node joined.
    {:ok, %{}, {:continue, :reload}}
  end

  @impl GenServer
  def handle_continue(:reload, state) do
    do_reload()
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:reload, _from, state) do
    do_reload()
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info({:match_created, id}, state) do
    :ets.insert_new(@table, {id, 0, 0})
    notify({:match_added, id})
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:goal, id, team}, state) do
    apply_goal(id, team)
    {:noreply, state}
  end

  defp apply_goal(id, team) do
    case fetch_score(id) do
      {:ok, _score} ->
        :ets.update_counter(@table, id, {position(team), 1})
        {:ok, score} = fetch_score(id)
        notify({:score_updated, id, score})

      :error ->
        recover_row(id)
    end
  end

  # A goal for an unknown match proves this board missed events (it joined
  # late or blipped through the creation), so counting from zero would bake
  # the loss in. Recover from the source of truth instead — it already
  # includes this goal, because matches bump state before broadcasting.
  defp recover_row(id) do
    case Matches.authoritative_score(id) do
      {:ok, %{home: home, away: away} = score} ->
        :ets.insert(@table, {id, home, away})
        notify({:match_added, id})
        notify({:score_updated, id, score})

      {:error, :match_not_found} ->
        # No reachable source of truth: fabricating a row would bake invalid
        # state in. Drop the event; the next goal retries the recovery.
        Logger.error(
          "Board dropped goal for unknown match #{inspect(id)}: no authoritative source"
        )
    end
  end

  defp position(:home), do: 2
  defp position(:away), do: 3

  defp do_reload do
    ScoreBoard.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(
      Matches.list_matches(),
      fn id -> {id, Matches.authoritative_score(id)} end,
      ordered: false,
      on_timeout: :kill_task
    )
    |> Enum.each(fn
      # Inserts stay in the Board process: the table is protected, tasks
      # only perform the (possibly remote) calls.
      {:ok, {id, {:ok, %{home: home, away: away}}}} -> :ets.insert(@table, {id, home, away})
      _dead_match_or_timeout -> :ok
    end)

    notify(:board_reloaded)
  end

  # local_broadcast: the derived board is per-node state — a blipped node
  # must not push its staleness to peers.
  defp notify(event) do
    Phoenix.PubSub.local_broadcast(ScoreBoard.PubSub, @updates_topic, event)
  end
end
