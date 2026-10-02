defmodule EventstoreSqlite.Repo.Migrations.CreateArchiveTables do
  use Ecto.Migration

  def up do
    execute(fn -> EventstoreSqlite.Migration.check_archives_stream_free!(repo()) end)

    create table(:archived_streams) do
      add(:stream_id, :text, null: false)
      add(:stream_version, :integer, null: false)
      add(:created_at, :utc_datetime, null: false)
      add(:archived_at, :utc_datetime, null: false)
    end

    create table(:archived_stream_events, primary_key: false) do
      add(:archive_id, references(:archived_streams), null: false)
      add(:event_id, references(:events, type: :binary), null: false)
      add(:stream_version, :integer, null: false)
      add(:all_position, :integer, null: false)
    end

    create(index(:archived_streams, [:stream_id]))
    create(unique_index(:archived_stream_events, [:archive_id, :stream_version]))
  end

  def down do
    execute(fn -> EventstoreSqlite.Migration.check_no_archives!(repo()) end)

    drop(table(:archived_stream_events))
    drop(table(:archived_streams))
  end
end
