defmodule EventstoreSqlite.Repo.Migrations.AddSyncCursorAppliedAt do
  use Ecto.Migration

  def up do
    execute("ALTER TABLE sync_cursors ADD COLUMN applied_at TEXT")
  end

  def down do
    execute("ALTER TABLE sync_cursors DROP COLUMN applied_at")
  end
end
