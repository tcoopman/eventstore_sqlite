defmodule EventstoreSqlite.Migration do
  @moduledoc false
  alias Ecto.Adapters.SQL

  @all_stream_id "$all"

  @doc """
  Rebuilds `$all` from the events of every non-system stream.

  `$all` is renumbered `0..n-1` in the order the events were appended, so every
  `$all` position saved before the rebuild is invalid afterwards: `$all`
  subscribers have to start over.
  """
  def intial_fill_all do
    EventstoreSqlite.RepoWrite.transact(fn repo ->
      system_streams = EventstoreSqlite.system_streams()
      placeholders = Enum.map_join(1..length(system_streams), ", ", &"?#{&1 + 1}")

      SQL.query!(repo, "DELETE FROM stream_events WHERE stream_id = ?1", [@all_stream_id])
      upsert_all_stream(repo, 0)

      %{num_rows: count} =
        SQL.query!(
          repo,
          """
          INSERT INTO stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version)
          SELECT event_id, ?1, row_number() OVER (ORDER BY id) - 1, stream_id, stream_version
          FROM stream_events
          WHERE stream_id NOT IN (#{placeholders})
          ORDER BY id
          """,
          [@all_stream_id | system_streams]
        )

      upsert_all_stream(repo, count)

      {:ok, :done}
    end)
  end

  defp upsert_all_stream(repo, stream_version) do
    repo.insert!(%EventstoreSqlite.Stream{stream_id: @all_stream_id, stream_version: stream_version},
      on_conflict: [set: [stream_version: stream_version]],
      conflict_target: :stream_id
    )
  end

  @archives_stream_id "$archives"

  @doc """
  Raises when a user stream named `$archives` already exists, because
  eventstore_sqlite reserves that name for its archive log.
  """
  def check_archives_stream_free!(repo) do
    %{rows: [[streams, events]]} =
      SQL.query!(
        repo,
        """
        SELECT (SELECT count(*) FROM streams WHERE stream_id = ?1),
               (SELECT count(*) FROM stream_events WHERE stream_id = ?1)
        """,
        [@archives_stream_id]
      )

    if streams + events > 0 do
      raise """
      A stream named "#{@archives_stream_id}" already exists (#{events} events). \
      eventstore_sqlite now reserves this name for its archive log. Copy its \
      events to a stream with another name and remove it, then run the migration \
      again.
      """
    end

    :ok
  end

  @doc """
  Raises when a user stream named `stream_id` already exists, because
  eventstore_sqlite reserves that name.
  """
  def check_stream_name_free!(repo, stream_id) do
    %{rows: [[streams, events]]} =
      SQL.query!(
        repo,
        """
        SELECT (SELECT count(*) FROM streams WHERE stream_id = ?1),
               (SELECT count(*) FROM stream_events WHERE stream_id = ?1)
        """,
        [stream_id]
      )

    if streams + events > 0 do
      raise """
      A stream named "#{stream_id}" already exists (#{events} events). \
      eventstore_sqlite now reserves this name. Copy its events to a stream \
      with another name and remove it, then run the migration again.
      """
    end

    :ok
  end

  @doc """
  Raises when sync has ever been enabled, because dropping the sync tables
  would lose the log of entries peers haven't pulled yet, and the store's
  `"$sync"` and `"$ownership"` events would be read as ordinary streams.
  """
  def check_no_sync_history!(repo) do
    case SQL.query!(repo, "SELECT count(*) FROM streams WHERE stream_id IN ('$sync', '$ownership')") do
      %{rows: [[0]]} ->
        :ok

      _ ->
        raise """
        Refusing to drop the sync tables: sync has been enabled on this store, so \
        it holds "$sync" and "$ownership" events and possibly log entries a \
        peer hasn't pulled. Rolling back past this migration isn't supported \
        once sync has been used.
        """
    end
  end

  @doc """
  Raises when any stream has been archived, because dropping the archive tables
  would lose which stream and versions the archived events belonged to.
  """
  def check_no_archives!(repo) do
    case SQL.query!(repo, "SELECT count(*) FROM archived_streams") do
      %{rows: [[0]]} ->
        :ok

      %{rows: [[count]]} ->
        raise """
        Refusing to drop the archive tables: they hold #{count} archived streams, \
        and the archive tables are the only record of which stream and versions \
        those events belonged to. Back up or restore them first.
        """
    end
  end

  @doc """
  Rebuilds `stream_events` with `stream_id` and `original_stream_id` declared as
  `column_type` (`"TEXT"` or `"INTEGER"`), keeping every row, its `id`, the
  table's AUTOINCREMENT counter, and its indexes and triggers.

  With `"TEXT"`, values SQLite stored as numbers are turned back into the stream
  names they came from. That is exact: the foreign key to `streams.stream_id`
  (TEXT) only accepted a number whose text form equals the stream's name.
  Raises, before anything is dropped, if the copied rows fail
  `PRAGMA foreign_key_check`.
  """
  def rebuild_stream_events(repo, column_type) when column_type in ["TEXT", "INTEGER"] do
    %{rows: schema_objects} =
      SQL.query!(
        repo,
        "SELECT sql FROM sqlite_master WHERE tbl_name = 'stream_events' AND type IN ('index', 'trigger') AND sql IS NOT NULL ORDER BY type, name"
      )

    SQL.query!(repo, "ALTER TABLE stream_events RENAME TO stream_events_old")

    SQL.query!(repo, """
    CREATE TABLE "stream_events" (
      "id" INTEGER PRIMARY KEY AUTOINCREMENT,
      "event_id" BLOB CONSTRAINT "stream_events_event_id_fkey" REFERENCES "events"("id"),
      "stream_id" #{column_type} CONSTRAINT "stream_events_stream_id_fkey" REFERENCES "streams"("stream_id"),
      "stream_version" INTEGER NOT NULL,
      "original_stream_id" #{column_type} CONSTRAINT "stream_events_original_stream_id_fkey" REFERENCES "streams"("stream_id"),
      "original_stream_version" INTEGER
    )
    """)

    try do
      SQL.query!(repo, """
      INSERT INTO stream_events (id, event_id, stream_id, stream_version, original_stream_id, original_stream_version)
      SELECT id, event_id, #{copy_stream_id("stream_id", column_type)}, stream_version,
             #{copy_stream_id("original_stream_id", column_type)}, original_stream_version
      FROM stream_events_old
      ORDER BY id
      """)
    rescue
      error in Exqlite.Error ->
        if error.message =~ "FOREIGN KEY constraint failed" do
          raise """
          cannot rebuild stream_events with #{column_type} stream ids: some stream \
          names can't be stored that way. #{column_type} columns turn a name like \
          "007" into the number 7, which no longer matches its stream. Nothing was \
          changed. Rolling back past this migration is only possible while no \
          stream has such a name.
          """
        else
          reraise error, __STACKTRACE__
        end
    end

    case SQL.query!(repo, "PRAGMA foreign_key_check(stream_events)") do
      %{rows: []} ->
        :ok

      %{rows: violations} ->
        raise """
        cannot rebuild stream_events: #{length(violations)} rows don't match a \
        stream in streams after the copy. Nothing was changed. List them with:

        PRAGMA foreign_key_check(stream_events);
        """
    end

    %{rows: [[sequence]]} =
      SQL.query!(repo, "SELECT max(seq) FROM sqlite_sequence WHERE name IN ('stream_events', 'stream_events_old')")

    SQL.query!(repo, "DELETE FROM sqlite_sequence WHERE name = 'stream_events'")

    if sequence do
      SQL.query!(repo, "INSERT INTO sqlite_sequence (name, seq) VALUES ('stream_events', ?1)", [sequence])
    end

    SQL.query!(repo, "DROP TABLE stream_events_old")
    Enum.each(schema_objects, fn [sql] -> SQL.query!(repo, sql) end)

    :ok
  end

  defp copy_stream_id(column, "TEXT"), do: "CAST(#{column} AS TEXT)"
  defp copy_stream_id(column, "INTEGER"), do: column

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
