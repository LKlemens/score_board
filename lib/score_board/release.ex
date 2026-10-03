defmodule ScoreBoard.Release do
  @moduledoc """
  Release tasks, run from the entrypoint before the app boots.

  `migrate/0` is a no-op without `DATABASE_URL`, so the demo deploys with or
  without Postgres.
  """
  @app :score_board

  @doc "Runs pending migrations, when a database is configured."
  @spec migrate() :: :ok
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _result, _apps} =
        Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  defp repos do
    if Application.get_env(@app, ScoreBoard.Repo)[:url],
      do: Application.fetch_env!(@app, :ecto_repos),
      else: []
  end

  defp load_app do
    Application.load(@app)
    Application.ensure_all_started(:ssl)
  end
end
