defmodule EventstoreSqlite.Repo.Migrations.CreateSyncTables do
  use Ecto.Migration

  def up do
    execute(fn -> EventstoreSqlite.Migration.check_stream_name_free!(repo(), "$sync") end)
    execute(fn -> EventstoreSqlite.Migration.check_stream_name_free!(repo(), "$ownership") end)

    execute("""
    CREATE TABLE sync_log (
      seq INTEGER PRIMARY KEY AUTOINCREMENT,
      kind TEXT NOT NULL,
      stream_id TEXT,
      stream_version INTEGER,
      generation INTEGER,
      payload BLOB,
      inserted_at TEXT NOT NULL
    )
    """)

    execute("""
    CREATE TABLE sync_log_events (
      seq INTEGER NOT NULL,
      position INTEGER NOT NULL,
      event_id TEXT NOT NULL,
      PRIMARY KEY (seq, position)
    )
    """)

    execute("""
    CREATE TABLE sync_cursors (
      origin TEXT PRIMARY KEY,
      seq INTEGER NOT NULL,
      origin_head INTEGER,
      origin_diverged INTEGER NOT NULL DEFAULT 0
    )
    """)

    execute("CREATE TABLE sync_acks (peer TEXT PRIMARY KEY, seq INTEGER NOT NULL)")

    execute("""
    CREATE TABLE sync_quarantine (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      origin TEXT NOT NULL,
      seq INTEGER NOT NULL,
      entry BLOB NOT NULL,
      reason TEXT NOT NULL,
      inserted_at TEXT NOT NULL
    )
    """)

    execute("CREATE TABLE sync_state (key TEXT PRIMARY KEY, value BLOB NOT NULL)")
  end

  def down do
    execute(fn -> EventstoreSqlite.Migration.check_no_sync_history!(repo()) end)

    for table <- ~w(sync_state sync_quarantine sync_acks sync_cursors sync_log_events sync_log) do
      execute("DROP TABLE #{table}")
    end
  end
end
