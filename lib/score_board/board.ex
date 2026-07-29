defmodule ScoreBoard.Board do
  @moduledoc """
  Per-node derived scoreboard for all matches.

  Subscribes to match events and folds them into a public-read ETS table.
  This is deliberately a cache: a missed event leaves this node's board
  permanently wrong — the failure mode the demo showcases. `reload/1`
  rebuilds the table from the true scores held by the match processes.

  Writes serialize through the GenServer; reads go straight to ETS.

  One board per node runs under the default name in the application tree;
  extra instances can be started under any `:name` (also the ETS table
  name) with their own `:topic` — used by tests to isolate suites.
  """
  use GenServer

  require Logger

  alias ScoreBoard.Match
  alias ScoreBoard.Matches

  @typedoc "A board's registered name, doubling as its ETS table name."
  @type board_name :: atom()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    topic = Keyword.get(opts, :topic, Match.topic())
    GenServer.start_link(__MODULE__, {name, topic}, name: name)
  end

  @doc "All matches this board knows about, keyed by match id."
  @spec scores(board_name()) :: %{Matches.match_id() => Match.score()}
  def scores(board \\ __MODULE__) do
    board
    |> :ets.tab2list()
    |> Map.new(fn {id, home, away} -> {id, %{home: home, away: away}} end)
  end

  @doc """
  This board's derived score for one match.

  Safe to call even before the table exists (a Horde-restarted match uses
  it during startup to re-seed its score).
  """
  @spec fetch_score(board_name(), Matches.match_id()) :: {:ok, Match.score()} | :error
  def fetch_score(board \\ __MODULE__, id) do
    case :ets.lookup(board, id) do
      [{^id, home, away}] -> {:ok, %{home: home, away: away}}
      [] -> :error
    end
  rescue
    ArgumentError -> :error
  end

  @doc """
  Subscribes the caller to this board's updates: `{:match_added, id}`,
  `{:score_updated, id, score}`, and `:board_reloaded`.

  Emitted after ETS is written, so unlike subscribing to raw match events
  there is no window where a reader sees a stale board with no further
  update coming.
  """
  @spec subscribe(board_name()) :: :ok | {:error, term()}
  def subscribe(board \\ __MODULE__) do
    Phoenix.PubSub.subscribe(ScoreBoard.PubSub, updates_topic(board))
  end

  @doc """
  Rebuilds the derived table from the true scores — the recovery path for
  a board that knows it missed events.
  """
  @spec reload(board_name()) :: :ok
  def reload(board \\ __MODULE__) do
    GenServer.call(board, :reload)
  end

  @impl GenServer
  def init({name, topic}) do
    :ets.new(name, [:named_table, :protected, read_concurrency: true])
    :ok = Phoenix.PubSub.subscribe(ScoreBoard.PubSub, topic)
    state = %{table: name, updates_topic: updates_topic(name)}
    # Catch up on matches that existed before this board started.
    {:ok, state, {:continue, :reload}}
  end

  @impl GenServer
  def handle_continue(:reload, state) do
    do_reload(state)
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:reload, _from, state) do
    do_reload(state)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info({:match_created, id}, state) do
    :ets.insert_new(state.table, {id, 0, 0})
    notify(state, {:match_added, id})
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:goal, id, team}, state) do
    apply_goal(state, id, team)
    {:noreply, state}
  end

  defp apply_goal(state, id, team) do
    case fetch_score(state.table, id) do
      {:ok, _score} ->
        :ets.update_counter(state.table, id, {position(team), 1})
        {:ok, score} = fetch_score(state.table, id)
        notify(state, {:score_updated, id, score})

      :error ->
        recover_row(state, id)
    end
  end

  # A goal for an unknown match proves this board missed events (it started
  # late or the events were lost), so counting from zero would bake the
  # loss in. Recover from the source of truth instead — it already includes
  # this goal, because matches bump state before broadcasting.
  defp recover_row(state, id) do
    case Matches.score(id) do
      {:ok, %{home: home, away: away} = score} ->
        :ets.insert(state.table, {id, home, away})
        notify(state, {:match_added, id})
        notify(state, {:score_updated, id, score})

      {:error, :match_not_found} ->
        # No reachable source of truth: fabricating a row would bake invalid
        # state in. Drop the event; the next goal retries the recovery.
        Logger.error(
          "Board dropped goal for unknown match #{inspect(id)}: no reachable match process"
        )
    end
  end

  defp position(:home), do: 2
  defp position(:away), do: 3

  defp do_reload(state) do
    ids = Matches.list_matches()

    results =
      Task.Supervisor.async_stream_nolink(
        ScoreBoard.TaskSupervisor,
        ids,
        &Matches.score/1,
        on_timeout: :kill_task
      )

    # Inserts stay in the Board process: the table is protected, tasks only
    # perform the (possibly remote) calls. Zipping keeps the id available
    # for results that carry none (task exits/timeouts).
    ids
    |> Enum.zip(results)
    |> Enum.each(fn
      {id, {:ok, {:ok, %{home: home, away: away}}}} ->
        :ets.insert(state.table, {id, home, away})

      {id, {:ok, {:error, :match_not_found}}} ->
        Logger.warning("Board reload skipped match #{inspect(id)}: no reachable match process")

      {id, {:exit, reason}} ->
        Logger.warning("Board reload skipped match #{inspect(id)}: #{inspect(reason)}")
    end)

    notify(state, :board_reloaded)
  end

  # local_broadcast: the derived board is per-node state — a stale board
  # must not push its staleness to peers.
  defp notify(state, event) do
    Phoenix.PubSub.local_broadcast(ScoreBoard.PubSub, state.updates_topic, event)
  end

  defp updates_topic(__MODULE__), do: "board:updates"
  defp updates_topic(board), do: "board:updates:#{inspect(board)}"
end
