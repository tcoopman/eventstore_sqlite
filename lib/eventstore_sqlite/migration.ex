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

  @event_id_index "stream_events_fill_all_origins_event_id_index"

  @original_streams_query ~s"""
  SELECT a.event_id, a.stream_version AS all_position,
    (SELECT count(*) FROM stream_events o
     WHERE o.event_id = a.event_id AND o.stream_id <> '#{@all_stream_id}') AS original_streams
  FROM stream_events a
  WHERE a.stream_id = '#{@all_stream_id}'
  """

  @doc """
  Points every `$all` row's `original_stream_id` / `original_stream_version` at
  the stream row it was appended through.

  Each `$all` row must have exactly one original stream: one non-`$all` row
  with the same `event_id`. If any row has none or several, this raises before changing anything. Run it
  inside a transaction (a migration is one) so a raise also restores the
  `no_update_stream_events` trigger it drops while updating, and removes the
  temporary `event_id` index it matches rows with.
  """
  def fill_all_origins(repo) do
    SQL.query!(repo, "CREATE INDEX #{@event_id_index} ON stream_events (event_id)")
    check_exactly_one_original_stream!(repo)

    without_update_guard(repo, fn ->
      SQL.query!(repo, ~s"""
      UPDATE stream_events AS a
      SET original_stream_id = o.stream_id,
          original_stream_version = o.stream_version
      FROM stream_events AS o
      WHERE a.stream_id = '#{@all_stream_id}'
        AND o.event_id = a.event_id
        AND o.stream_id <> '#{@all_stream_id}'
      """)
    end)

    case SQL.query!(repo, "SELECT count(*) FROM stream_events WHERE stream_id = ?1 AND original_stream_id = ?1", [
           @all_stream_id
         ]) do
      %{rows: [[0]]} -> :ok
      %{rows: [[count]]} -> raise "#{count} $all rows still have $all as their origin after the update"
    end

    SQL.query!(repo, "DROP INDEX #{@event_id_index}")
    :ok
  end

  defp check_exactly_one_original_stream!(repo) do
    %{rows: [[without_original_stream, with_several_original_streams]]} =
      SQL.query!(repo, """
      SELECT coalesce(sum(original_streams = 0), 0), coalesce(sum(original_streams > 1), 0)
      FROM (#{@original_streams_query})
      """)

    if without_original_stream + with_several_original_streams > 0 do
      raise """
      cannot fill the origin of the $all events: every $all row needs exactly one \
      original stream (a row with the same event_id in another stream), but \
      #{without_original_stream} $all rows have no original stream and \
      #{with_several_original_streams} have more than one. Nothing was changed.

      List them with:

      SELECT * FROM (#{String.trim(@original_streams_query)}) WHERE original_streams <> 1;

      Repair those rows by hand, then run the migration again.
      """
    end
  end

  defp without_update_guard(repo, fun) do
    %{rows: [[trigger_sql]]} =
      SQL.query!(repo, "SELECT sql FROM sqlite_master WHERE type = 'trigger' AND name = 'no_update_stream_events'")

    SQL.query!(repo, "DROP TRIGGER no_update_stream_events")
    fun.()
    SQL.query!(repo, trigger_sql)
  end
end
