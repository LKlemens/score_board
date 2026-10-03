defmodule ScoreBoard.Repo.Migrations.CreateStatsDigests do
  use Ecto.Migration

  def change do
    create table(:stats_digests) do
      add(:sent_on, :date, null: false)
      add(:visits, :integer, null: false)
      add(:rejected, :integer, null: false)
      add(:peak_online, :integer, null: false)
      # False when the day was recorded but nothing had changed to report.
      add(:sent, :boolean, null: false, default: true)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:stats_digests, [:sent_on]))
  end
end
