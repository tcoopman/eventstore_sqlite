defmodule EventstoreSqlite.Repo.Migrations.TextStreamIds do
  use Ecto.Migration

  def up do
    execute(fn -> EventstoreSqlite.Migration.rebuild_stream_events(repo(), "TEXT") end)
  end

  def down do
    execute(fn -> EventstoreSqlite.Migration.rebuild_stream_events(repo(), "INTEGER") end)
  end
end
