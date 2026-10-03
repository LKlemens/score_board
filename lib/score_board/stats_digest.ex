defmodule ScoreBoard.StatsDigest do
  @moduledoc "One day's visitor summary, and whether it was worth sending."
  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "stats_digests" do
    field(:sent_on, :date)
    field(:visits, :integer)
    field(:rejected, :integer)
    field(:peak_online, :integer)
    field(:sent, :boolean)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
