defmodule ScoreBoard.LanePool do
  @moduledoc """
  Boots the fixed pool of tenant lanes and the tracker that hands them out.

  Each lane gets its own EchoPubSub instance (its group name doubles as the
  lane's pubsub), pre-started here so assignment is instant. Per-lane fault
  injection (the "go offline" switch) keys off that group, so one tenant going
  offline never touches another.
  """
  use Supervisor

  alias ScoreBoard.Lane

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(_opts), do: Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl Supervisor
  def init(:ok) do
    lane_children =
      Enum.flat_map(Lane.ids(), fn id ->
        [
          Supervisor.child_spec(
            {Phoenix.PubSub,
             name: Lane.pubsub(id),
             adapter: EchoPubSub,
             pool_size: 1,
             buffer_size: Lane.buffer_size()},
            id: {:lane_bus, id}
          ),
          Supervisor.child_spec({ScoreBoard.DB, id}, id: {:lane_db, id}),
          Supervisor.child_spec({ScoreBoard.Board, id}, id: {:lane_board, id})
        ]
      end)

    Supervisor.init(lane_children ++ [ScoreBoard.Lanes], strategy: :one_for_one)
  end
end
