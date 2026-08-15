defmodule ScoreBoard.Board do
  @moduledoc """
  Per-node derived scoreboard for all matches.

  Subscribes to match events and folds them into a public-read ETS table.
  This is deliberately a cache: a missed event leaves this node's board
  permanently wrong - the failure mode the demo showcases. `reload/1`
  rebuilds the table from the scores stored in `ScoreBoard.DB`.

  Writes serialize through the GenServer; reads go straight to ETS.

  One board per node runs in the application tree. The registered name
  (also the ETS table name) and the events topic are resolved through the
  `ScoreBoard.Board.Helper` effects, which tests rebind (efx) to run fully
  isolated per-test instances.
  """
  use GenServer

  require Logger

  alias ScoreBoard.DB
  alias ScoreBoard.EchoPubSub
  alias ScoreBoard.Match
  alias ScoreBoard.Matches

  @typedoc "A board's registered name, doubling as its ETS table name."
  @type board_name :: atom()

  defmodule Helper do
    @moduledoc false
    # The board name (also its ETS table) and events topic. Effects, so
    # tests can rebind them: efx resolves bindings by walking $ancestors,
    # which reaches processes the test supervises - including this board's
    # own init. Match processes live under the app's Horde tree (no test
    # ancestor), so they always resolve the defaults.
    use Efx

    @spec name() :: ScoreBoard.Board.board_name()
    defeffect name do
      ScoreBoard.Board
    end

    @spec topic() :: String.t()
    defeffect topic do
      ScoreBoard.Match.topic()
    end
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: Helper.name())
  end

  @doc "All matches this board knows about, keyed by match id."
  @spec scores() :: %{Matches.match_id() => Match.score()}
  def scores do
    Helper.name()
    |> :ets.tab2list()
    |> Map.new(fn {id, home, away} -> {id, %{home: home, away: away}} end)
  end

  @doc """
  This board's derived score for one match.

  Safe to call even before the table exists (a Horde-restarted match uses
  it during startup to re-seed its score).
  """
  @spec fetch_score(Matches.match_id()) :: {:ok, Match.score()} | :error
  def fetch_score(id) do
    case :ets.lookup(Helper.name(), id) do
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
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    Phoenix.PubSub.subscribe(ScoreBoard.PubSub, updates_topic(Helper.name()))
  end

  @doc """
  Rebuilds the derived table from the true scores - the recovery path for
  a board that knows it missed events.
  """
  @spec reload() :: :ok
  def reload do
    GenServer.call(Helper.name(), :reload)
  end

  @impl GenServer
  def init(:ok) do
    :ets.new(Helper.name(), [:named_table, :protected, read_concurrency: true])
    # Match events ride the EchoPubSub instance; the board's own update
    # notifications stay on the default (PG2) instance below.
    :ok = EchoPubSub.subscribe(Helper.topic())
    # No state: the table and topics resolve through the Helper effects,
    # in this process too. The boot reload reads the cluster DB, whose
    # :global name is already synced by the time this node's tree starts.
    {:ok, nil, {:continue, :reload}}
  end

  @impl GenServer
  def handle_continue(:reload, state) do
    attempt_boot_reload()
    {:noreply, state}
  end

  # The DB may still be starting (its starter task does not block the
  # supervision tree) or its registration still syncing when this board
  # boots; reload once it is visible.
  defp attempt_boot_reload do
    if DB.alive?() do
      do_reload()
    else
      Process.send_after(self(), :retry_boot_reload, 500)
    end
  end

  @impl GenServer
  def handle_call(:reload, _from, state) do
    do_reload()
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info(:retry_boot_reload, state) do
    attempt_boot_reload()
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:match_created, id, %{home: home, away: away}}, state) do
    # Overwrite, not insert_new: a restarted or moved match re-announces
    # itself with its current score and the row must follow it.
    :ets.insert(Helper.name(), {id, home, away})
    notify({:match_added, id})
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:goal, id, team}, state) do
    apply_goal(id, team)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:cursor_expired, from_node}, state) do
    # This board fell off a producer's ring buffer: the gap is gone for
    # good, so rebuild from the source of truth instead of waiting.
    Logger.warning(
      "Board fell behind producer on #{inspect(from_node)}; reloading from match processes"
    )

    do_reload()
    {:noreply, state}
  end

  defp apply_goal(id, team) do
    case fetch_score(id) do
      {:ok, _score} ->
        :ets.update_counter(Helper.name(), id, {position(team), 1})
        {:ok, score} = fetch_score(id)
        notify({:score_updated, id, score})

      :error ->
        recover_row(id)
    end
  end

  # A goal for an unknown match proves this board missed events (it started
  # late or the events were lost), so counting from zero would bake the
  # loss in. Recover from the DB instead - it already includes this goal,
  # because matches write through before broadcasting.
  defp recover_row(id) do
    case DB.read(id) do
      {:ok, %{home: home, away: away} = score} ->
        :ets.insert(Helper.name(), {id, home, away})
        notify({:match_added, id})
        notify({:score_updated, id, score})

      :error ->
        # No entry to recover from: fabricating a row would bake invalid
        # state in. Drop the event; the next goal retries the recovery.
        Logger.error("Board dropped goal for unknown match #{inspect(id)}: not in the DB")
    end
  end

  defp position(:home), do: 2
  defp position(:away), do: 3

  defp do_reload do
    Enum.each(DB.all(), fn {id, %{home: home, away: away}} ->
      :ets.insert(Helper.name(), {id, home, away})
    end)

    notify(:board_reloaded)
  end

  # local_broadcast: the derived board is per-node state - a stale board
  # must not push its staleness to peers. Publishes on the updates topic
  # (derived from the board name) - not Helper.topic(), which is the events
  # topic this board consumes.
  defp notify(event) do
    Phoenix.PubSub.local_broadcast(ScoreBoard.PubSub, updates_topic(Helper.name()), event)
  end

  defp updates_topic(__MODULE__), do: "board:updates"
  defp updates_topic(board), do: "board:updates:#{inspect(board)}"
end
