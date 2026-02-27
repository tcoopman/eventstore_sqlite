defmodule EventstoreSqlite.Migration do
  @moduledoc false
  alias Ecto.Adapters.SQL

  @all_stream_id "$all"

  def intial_fill_all do
    EventstoreSqlite.RepoWrite.transact(fn repo ->
      SQL.query!(repo, ~s"""
      DELETE FROM stream_events WHERE stream_id == '#{@all_stream_id}';
      """)

      SQL.query!(repo, ~s"""
      WITH stream_events_not_all (id, event_id, stream_id, stream_version)
      AS (select id, event_id, stream_id, stream_version from stream_events where stream_id <> '#{@all_stream_id}')
      INSERT INTO stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version)
      SELECT
        stream_events_not_all.event_id, '#{@all_stream_id}', stream_events_not_all.id, stream_events_not_all.stream_id, stream_events_not_all.stream_version
      FROM stream_events_not_all ORDER BY event_id
      RETURNING 1
      """)

      SQL.query!(repo, ~s"""
      UPDATE streams SET stream_version = (select max(stream_version) from stream_events where stream_id='$all')
      where stream_id = '$all'
      """)

      {:ok, :done}
    end)
  end
end
