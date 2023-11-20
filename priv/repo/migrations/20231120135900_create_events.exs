defmodule EventstoreSqlite.Repo.Migrations.CreateEvents do
  use Ecto.Migration

  def change do
    create table(:streams) do
      add(:stream_id, :text, null: false)
      add(:stream_version, :integer, null: false, default: 0)

      timestamps(updated_at: false, type: :utc_datetime)
    end

    # CREATE TABLE streams
    # (
    #   -- stream_uuid is not a guid
    # 		stream_id INTEGER PRIMARY KEY AUTOINCREMENT,
    # 		stream_uuid TEXT NOT NULL UNIQUE,
    # 		stream_version INTEGER DEFAULT 0 NOT NULL,
    #     created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL
    # );

    create table(:events, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:type, :text, null: false)
      add(:data, :text, null: false)
      add(:metadata, :text)

      timestamps(updated_at: false, type: :utc_datetime)
    end

    # CREATE TABLE events
    # (
    #     event_uuid TEXT PRIMARY KEY NOT NULL CHECK (event_uuid LIKE '________-____-____-____-____________'),
    #     event_type TEXT NOT NULL,
    #     causation_id TEXT NULL CHECK (causation_id LIKE '________-____-____-____-____________'),
    #     correlation_id TEXT NULL CHECK (correlation_id LIKE '________-____-____-____-____________'),
    #     data TEXT NOT NULL,
    #     metadata TEXT NULL,
    #     created_at TEXT DEFAULT CURRENT_TIMESTAMP NOT NULL
    # );

    create table(:stream_events) do
      add(:event_id, references(:events, type: :binary))
      add(:stream_id, references(:streams, column: :stream_id))
      add(:stream_version, :integer, null: false)
      add(:original_stream_id, references(:streams, column: :stream_id))
      add(:original_stream_version, :integer)

      timestamps(updated_at: false, inserted_at: false, type: :utc_datetime)
    end

    create(unique_index(:events, [:id]))
    create(unique_index(:streams, [:stream_id]))
    create(unique_index(:stream_events, [:stream_id, :stream_version]))

    # CREATE TABLE stream_events
    # (
    #   event_uuid TEXT NOT NULL REFERENCES events (event_uuid),
    #   stream_id INTEGER NOT NULL REFERENCES streams (stream_id),
    #   stream_version INTEGER NOT NULL,
    #   original_stream_id INTEGER REFERENCES streams (stream_id),
    #   original_stream_version INTEGER,
    #   PRIMARY KEY(event_uuid, stream_id)
    # );
  end
end
