defmodule ScoreBoard.Repo do
  @moduledoc """
  Postgres, used only to keep the dashboard's numbers across restarts.

  Optional: with no `DATABASE_URL` the repo is not started and
  `ScoreBoard.StatsStore` degrades to in-memory counters. Nothing in the
  scoreboard itself touches it - match state stays in `ScoreBoard.DB`.
  """
  use Ecto.Repo, otp_app: :score_board, adapter: Ecto.Adapters.Postgres
end
