defmodule ScoreBoard.Board do
  @moduledoc """
  Per-node, per-lane derived scoreboard for all of a lane's matches.

  Subscribes to the lane's match events and folds them into a public-read ETS
  table. This is deliberately a cache: a missed event leaves this node's board
  permanently wrong - the failure mode the demo showcases. `reload/1` rebuilds
  the table from the scores stored in the lane's `ScoreBoard.DB` replica.

  Writes serialize through the GenServer; reads go straight to ETS. One board
  per node per lane runs under the lane pool; its registered name and ETS table
  are `ScoreBoard.Lane.board/1`.
  """
  use GenServer

  require Logger

  alias ScoreBoard.Blip
  alias ScoreBoard.DB
  alias ScoreBoard.EchoPubSub
  alias ScoreBoard.Lane
  alias ScoreBoard.Match
  alias ScoreBoard.Matches

  @spec start_link(Lane.id()) :: GenServer.on_start()
  def start_link(lane) do
    GenServer.start_link(__MODULE__, lane, name: Lane.board(lane))
  end

  @doc "All matches this lane's board knows about, keyed by match id."
  @spec scores(Lane.id()) :: %{Matches.match_id() => Match.score()}
  def scores(lane) do
    Lane.board(lane)
    |> :ets.tab2list()
    |> Map.new(fn {id, home, away} -> {id, %{home: home, away: away}} end)
  rescue
    ArgumentError -> %{}
  end

  @doc """
  This board's derived score for one match.

  Safe to call even before the table exists (a Horde-restarted match uses it
  during startup to re-seed its score).
  """
  @spec fetch_score(Lane.id(), Matches.match_id()) :: {:ok, Match.score()} | :error
  def fetch_score(lane, id) do
    case :ets.lookup(Lane.board(lane), id) do
      [{^id, home, away}] -> {:ok, %{home: home, away: away}}
      [] -> :error
    end
  rescue
    ArgumentError -> :error
  end

  @doc """
  Subscribes the caller to this lane's board updates: `{:match_added, id}`,
  `{:score_updated, id, score}`, `{:match_removed, id}`, and `:board_reloaded`.
  """
  @spec subscribe(Lane.id()) :: :ok | {:error, term()}
  def subscribe(lane) do
    Phoenix.PubSub.subscribe(ScoreBoard.PubSub, updates_topic(lane))
  end

  @doc "Rebuilds the derived table from the lane's true scores."
  @spec reload(Lane.id()) :: :ok
  def reload(lane) do
    GenServer.call(Lane.board(lane), :reload)
  end

  @impl GenServer
  def init(lane) do
    table = Lane.board(lane)
    :ets.new(table, [:named_table, :protected, read_concurrency: true])
    # Match events ride the lane's EchoPubSub instance; the board's own update
    # notifications stay on the shared (PG2) instance.
    :ok = EchoPubSub.subscribe(Lane.pubsub(lane), Match.topic())

    {:ok, %{lane: lane, table: table, by_ref: %{}, by_id: %{}}, {:continue, :reload}}
  end

  @impl GenServer
  def handle_continue(:reload, state) do
    {:noreply, attempt_boot_reload(state)}
  end

  # The DB replica may still be starting when this board boots; reload once
  # it is visible.
  defp attempt_boot_reload(state) do
    if DB.alive?(state.lane) do
      do_reload(state)
    else
      Process.send_after(self(), :retry_boot_reload, 500)
      state
    end
  end

  @impl GenServer
  def handle_call(:reload, _from, state) do
    {:reply, :ok, do_reload(state)}
  end

  @impl GenServer
  def handle_info(:retry_boot_reload, state) do
    {:noreply, attempt_boot_reload(state)}
  end

  @impl GenServer
  def handle_info({:match_created, id, score, pid}, state) do
    {:noreply, ingest(state, fn s -> apply_created(id, score, pid, s) end)}
  end

  @impl GenServer
  def handle_info({:goal, id, team}, state) do
    {:noreply, ingest(state, fn s -> apply_goal(id, team, s) end)}
  end

  @impl GenServer
  def handle_info(:db_merged, state) do
    # The DB absorbed a split-brain copy's rows; reload to backfill any we missed.
    Logger.info("DB merged after split-brain; reloading board")
    {:noreply, do_reload(state)}
  end

  @impl GenServer
  def handle_info({:cursor_expired, from_node}, state) do
    # This board fell off a producer's ring buffer: the gap is gone for good,
    # so rebuild from the source of truth instead of waiting.
    Logger.warning("Board fell behind producer on #{inspect(from_node)}; reloading from the DB")

    {:noreply, do_reload(state)}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    # A monitored match died: drop its row. A failover/rebalance restart
    # re-announces via match_created, which adds the row back.
    case Map.pop(state.by_ref, ref) do
      {nil, _} ->
        {:noreply, state}

      {id, by_ref} ->
        :ets.delete(state.table, id)
        notify(state, {:match_removed, id})
        {:noreply, %{state | by_ref: by_ref, by_id: Map.delete(state.by_id, id)}}
    end
  end

  # Local delivery bypasses echo's fault gate, so a blipped node would still see
  # events. Gate here too: while offline the board freezes (drops events).
  # Recovery is the explicit `reload/1` that going back online triggers.
  defp ingest(state, apply_fun) do
    if Blip.enabled?(state.lane), do: state, else: apply_fun.(state)
  end

  # Overwrite, not insert_new: a restarted or moved match re-announces itself
  # with its current score and the row must follow it.
  defp apply_created(id, %{home: home, away: away}, pid, state) do
    :ets.insert(state.table, {id, home, away})
    notify(state, {:match_added, id})
    monitor_match(id, pid, state)
  end

  defp apply_goal(id, team, state) do
    case fetch_score(state.lane, id) do
      {:ok, _score} ->
        :ets.update_counter(state.table, id, {position(team), 1})
        {:ok, score} = fetch_score(state.lane, id)
        notify(state, {:score_updated, id, score})
        state

      :error ->
        recover_row(id, state)
    end
  end

  # A goal for an unknown match proves this board missed events, so counting
  # from zero would bake the loss in. Recover from the DB instead - it already
  # includes this goal, because matches write through before broadcasting.
  defp recover_row(id, state) do
    case DB.read(state.lane, id) do
      {:ok, %{home: home, away: away} = score} ->
        :ets.insert(state.table, {id, home, away})
        notify(state, {:match_added, id})
        notify(state, {:score_updated, id, score})
        monitor_match(id, nil, state)

      :error ->
        Logger.error("Board dropped goal for unknown match #{inspect(id)}: not in the DB")
        state
    end
  end

  defp position(:home), do: 2
  defp position(:away), do: 3

  defp do_reload(state) do
    state =
      Enum.reduce(DB.all(state.lane), state, fn {id, %{home: home, away: away}}, state ->
        :ets.insert(state.table, {id, home, away})
        monitor_match(id, nil, state)
      end)

    notify(state, :board_reloaded)
    state
  end

  # Monitors the match process for `id` (looked up in the registry when no pid
  # is given), replacing any previous monitor so the latest incarnation wins.
  defp monitor_match(id, pid, state) do
    state = demonitor(id, state)

    case pid || GenServer.whereis(Matches.via(state.lane, id)) do
      pid when is_pid(pid) ->
        ref = Process.monitor(pid)
        %{state | by_ref: Map.put(state.by_ref, ref, id), by_id: Map.put(state.by_id, id, ref)}

      _ ->
        state
    end
  end

  defp demonitor(id, state) do
    case Map.pop(state.by_id, id) do
      {nil, _} ->
        state

      {ref, by_id} ->
        Process.demonitor(ref, [:flush])
        %{state | by_id: by_id, by_ref: Map.delete(state.by_ref, ref)}
    end
  end

  # local_broadcast: the derived board is per-node state - a stale board must
  # not push its staleness to peers.
  defp notify(state, event) do
    Phoenix.PubSub.local_broadcast(ScoreBoard.PubSub, updates_topic(state.lane), event)
  end

  defp updates_topic(lane), do: "board:updates:#{inspect(lane)}"
end
