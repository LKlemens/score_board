defmodule ScoreBoard.Lane do
  @moduledoc """
  Naming for one isolated tenant lane.

  A lane is identified by a small integer (1..`count/0`). Every per-lane
  process derives its registered name from that id here, so the pool, the
  engine, and the tests all agree on where a lane's event bus, DB replica,
  board, and matches live. Nothing in here starts a process - it is pure
  address arithmetic.
  """

  @type id :: pos_integer()

  @doc "All lane ids in the pool."
  @spec ids() :: [id()]
  def ids, do: Enum.to_list(1..count())

  @doc "How many lanes the pool pre-starts."
  @spec count() :: pos_integer()
  def count, do: Application.get_env(:score_board, :lane_count, 16)

  @doc "The ring-buffer size each lane's event bus keeps."
  @spec buffer_size() :: pos_integer()
  def buffer_size, do: Application.get_env(:score_board, :lane_buffer_size, 20)

  @doc "This lane's EchoPubSub instance name, which is also its pubsub group."
  @spec pubsub(id()) :: module()
  def pubsub(id), do: Module.concat(__MODULE__, "P#{id}")

  @doc "This lane's echo producer, derived from the group like the adapter does."
  @spec producer(id()) :: module()
  def producer(id), do: Module.concat(pubsub(id), Producer)

  @doc "This lane's DB replica name (used from Phase 3 on)."
  @spec db(id()) :: module()
  def db(id), do: Module.concat(__MODULE__, "DB#{id}")

  @doc "This lane's board process and ETS table name (used from Phase 3 on)."
  @spec board(id()) :: module()
  def board(id), do: Module.concat(__MODULE__, "Board#{id}")
end
