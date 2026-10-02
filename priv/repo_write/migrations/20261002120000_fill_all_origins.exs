defmodule EventstoreSqlite.Repo.Migrations.FillAllOrigins do
  use Ecto.Migration

  def up do
    execute(fn -> EventstoreSqlite.Migration.fill_all_origins(repo()) end)

    create(index(:stream_events, [:original_stream_id, :original_stream_version]))
  end

  def down do
    drop(index(:stream_events, [:original_stream_id, :original_stream_version]))
  end
end
