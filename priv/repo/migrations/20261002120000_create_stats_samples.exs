defmodule ScoreBoard.Repo.Migrations.CreateStatsSamples do
  use Ecto.Migration

  def change do
    create table(:stats_samples) do
      add :visits, :integer, null: false
      add :online, :integer, null: false
      add :peak_online, :integer, null: false
      add :rejected, :integer, null: false
      add :lanes_taken, :integer, null: false
      add :lanes_total, :integer, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:stats_samples, [:inserted_at])
  end
end
