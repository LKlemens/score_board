defmodule ScoreBoard.StatsSample do
  @moduledoc "One periodic row of dashboard counters."
  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "stats_samples" do
    field(:visits, :integer)
    field(:online, :integer)
    field(:peak_online, :integer)
    field(:rejected, :integer)
    field(:lanes_taken, :integer)
    field(:lanes_total, :integer)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
