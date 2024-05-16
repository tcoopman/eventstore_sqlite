defmodule EventstoreSqlite.Repo.Migrations.CreateTriggers do
  use Ecto.Migration

  def change do
    execute ~s"""
    CREATE TRIGGER no_update_stream_events BEFORE UPDATE ON stream_events
    BEGIN
    SELECT RAISE (FAIL, 'cannot update stream_events');
    END;
    """

    execute ~s"""
    CREATE TRIGGER no_update_events BEFORE UPDATE ON events
    BEGIN
      SELECT RAISE (FAIL, 'cannot update events');
    END;
    """

    execute ~s"""
    CREATE TRIGGER no_delete_events BEFORE DELETE ON events
    BEGIN
      SELECT RAISE (FAIL, 'cannot delete events');
    END;
    """
  end
end
