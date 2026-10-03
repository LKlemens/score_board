defmodule ScoreBoard.StatsStore do
  @moduledoc """
  Reads and writes the dashboard's persisted samples.

  Every function is a no-op (or an empty result) when the repo is not running,
  so the demo works with no database at all - that is the only difference
  between a deploy with `DATABASE_URL` and one without.
  """
  import Ecto.Query

  alias ScoreBoard.Repo
  alias ScoreBoard.Stats
  alias ScoreBoard.StatsSample

  @doc "Whether persistence is available right now."
  @spec enabled?() :: boolean()
  def enabled?, do: Process.whereis(Repo) != nil

  @doc "Cumulative totals from the newest sample, zeroes when there is none."
  @spec last_totals() :: %{visits: non_neg_integer(), rejected: non_neg_integer()}
  def last_totals do
    case latest() do
      nil -> %{visits: 0, rejected: 0}
      sample -> %{visits: sample.visits, rejected: sample.rejected}
    end
  end

  @doc "Stores one sample of the current counters."
  @spec record(Stats.snapshot()) :: :ok
  def record(snapshot) do
    if enabled?() do
      Repo.insert_all(StatsSample, [
        %{
          visits: snapshot.visits,
          online: snapshot.online,
          peak_online: snapshot.peak_online,
          rejected: snapshot.rejected,
          lanes_taken: snapshot.lanes.taken,
          lanes_total: snapshot.lanes.total,
          inserted_at: DateTime.utc_now()
        }
      ])
    end

    :ok
  end

  @doc "The most recent `limit` samples, oldest first, for the dashboard chart."
  @spec history(pos_integer()) :: [StatsSample.t()]
  def history(limit \\ 60) do
    if enabled?() do
      StatsSample
      |> order_by(desc: :inserted_at)
      |> limit(^limit)
      |> Repo.all()
      |> Enum.reverse()
    else
      []
    end
  end

  defp latest do
    if enabled?() do
      StatsSample |> order_by(desc: :inserted_at) |> limit(1) |> Repo.one()
    end
  end
end
