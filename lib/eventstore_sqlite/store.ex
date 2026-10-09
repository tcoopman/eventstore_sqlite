defmodule EventstoreSqlite.Store do
  @moduledoc false
  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL
  alias EventstoreSqlite.Event
  alias EventstoreSqlite.SystemEvents.StreamArchived

  @all_stream_id "$all"
  @archives_stream_id "$archives"

  # Max events per INSERT statement. Each event binds 5 parameters, so this keeps
  # us comfortably under SQLite's bound-parameter limit (SQLITE_MAX_VARIABLE_NUMBER)
  # for arbitrarily large appends.
  @insert_chunk_size 1_000

  def validate_version(_repo, _stream_id, :any_version), do: :ok

  def validate_version(repo, stream_id, expected_version)
      when expected_version == :no_stream or expected_version == {:version, 0} do
    if repo.exists?(from(stream in EventstoreSqlite.Stream, where: stream.stream_id == ^stream_id)) do
      {:error, :wrong_expected_version}
    else
      :ok
    end
  end

  def validate_version(repo, stream_id, :stream_exists) do
    if repo.exists?(from(stream in EventstoreSqlite.Stream, where: stream.stream_id == ^stream_id)) do
      :ok
    else
      {:error, :wrong_expected_version}
    end
  end

  def validate_version(repo, stream_id, {:version, version}) do
    if repo.exists?(
         from(stream in EventstoreSqlite.Stream,
           where: stream.stream_id == ^stream_id and stream.stream_version == ^version
         )
       ) do
      :ok
    else
      {:error, :wrong_expected_version}
    end
  end

  def stream_version(repo, stream_id) do
    repo.one(
      from(stream in EventstoreSqlite.Stream, where: stream.stream_id == ^stream_id, select: stream.stream_version)
    ) ||
      0
  end

  def insert_events(repo, events) do
    events
    |> Enum.chunk_every(@insert_chunk_size)
    |> Enum.each(fn chunk ->
      repo.insert_all(Event, Enum.map(chunk, &Map.drop(&1, [:__struct__, :__meta__])))
    end)
  end

  @doc """
  Inserts events exactly as they were read from another store: the same id,
  type, data, metadata and `inserted_at`, with `data` and `metadata` bound as
  blobs so their stored type doesn't change.
  """
  def insert_raw_events(repo, events) do
    events
    |> Enum.chunk_every(@insert_chunk_size)
    |> Enum.each(fn chunk ->
      placeholders = Enum.map_join(chunk, ",", fn _ -> "(?, ?, ?, ?, ?)" end)

      params =
        Enum.flat_map(chunk, fn event ->
          [event.id, event.type, blob(event.data), blob(event.metadata), event.inserted_at]
        end)

      SQL.query!(repo, "INSERT INTO events (id, type, data, metadata, inserted_at) VALUES #{placeholders}", params)
    end)
  end

  defp blob(nil), do: nil
  defp blob(binary), do: {:blob, binary}

  def insert_in_stream(repo, stream_id, entries) do
    stream =
      repo.one(from(stream in EventstoreSqlite.Stream, where: stream.stream_id == ^stream_id)) ||
        %EventstoreSqlite.Stream{stream_id: stream_id, stream_version: 0}

    stream_changeset =
      case stream.id do
        nil ->
          Ecto.Changeset.change(stream, stream_version: Enum.count(entries))

        _ ->
          Ecto.Changeset.change(stream, stream_version: stream.stream_version + Enum.count(entries))
      end

    repo.insert_or_update!(stream_changeset)

    rows =
      entries
      |> Enum.with_index(stream.stream_version)
      |> Enum.map(fn {{event_id, origin}, version} -> {event_id, version, origin || {stream_id, version}} end)

    rows
    |> Enum.chunk_every(@insert_chunk_size)
    |> Enum.each(fn chunk ->
      placeholders = Enum.map_join(chunk, ",", fn _ -> "(?, ?, ?, ?, ?)" end)

      params =
        Enum.flat_map(chunk, fn {event_id, version, {original_stream_id, original_stream_version}} ->
          [event_id, stream_id, version, original_stream_id, original_stream_version]
        end)

      query = ~s"""
      INSERT INTO stream_events (
        event_id, stream_id, stream_version, original_stream_id, original_stream_version
      )
      VALUES #{placeholders}
      """

      SQL.query!(repo, query, params)
    end)

    {:ok, Enum.map(rows, fn {event_id, version, _origin} -> {event_id, {stream_id, version}} end)}
  end

  @doc """
  Appends `event_ids` (already in `events`) to `stream_id` and to `"$all"`.
  Returns the first stream version they were written at.
  """
  def append_to_stream_and_all(repo, stream_id, event_ids) do
    {:ok, written} = insert_in_stream(repo, stream_id, Enum.map(event_ids, &{&1, nil}))
    {:ok, _} = insert_in_stream(repo, @all_stream_id, written)
    [{_, {^stream_id, first_version}} | _] = written
    {:ok, first_version}
  end

  @doc """
  Archives `stream_id` inside an open transaction. Returns
  `{:ok, event_count}`, where `event_count` is the number of events archived.
  """
  def archive_in_transaction(repo, stream_id, expected_version) do
    with {:ok, stream} <- fetch_stream(repo, stream_id),
         :ok <- validate_version(repo, stream_id, expected_version) do
      check_archivable!(repo, stream)
      archive_id = insert_archived_stream(repo, stream_id)
      copy_to_archive!(repo, archive_id, stream)
      delete_stream(repo, stream_id)

      append_system_event(repo, @archives_stream_id, %StreamArchived{
        stream_id: stream_id,
        archive_id: archive_id,
        event_count: stream.stream_version
      })

      {:ok, stream.stream_version}
    end
  end

  def append_system_event(repo, stream_id, data) do
    event = Event.new(data)
    :ok = insert_events(repo, [event])
    {:ok, _} = insert_in_stream(repo, stream_id, [{event.id, nil}])
    :ok
  end

  @doc """
  Reads the decoded data of every event in a system stream, oldest first,
  through `repo`, so a write transaction sees its own uncommitted events.
  """
  def system_stream_data(repo, stream_id) do
    %{rows: rows} =
      SQL.query!(
        repo,
        """
        SELECT e.data FROM stream_events s JOIN events e ON e.id = s.event_id
        WHERE s.stream_id = ?1 ORDER BY s.stream_version
        """,
        [stream_id]
      )

    Enum.map(rows, fn [data] -> :erlang.binary_to_term(data) end)
  end

  defp fetch_stream(repo, stream_id) do
    case repo.one(from(stream in EventstoreSqlite.Stream, where: stream.stream_id == ^stream_id)) do
      nil -> {:error, :stream_not_found}
      stream -> {:ok, stream}
    end
  end

  defp check_archivable!(repo, stream) do
    %{rows: [[stream_rows, all_rows]]} =
      SQL.query!(
        repo,
        """
        SELECT (SELECT count(*) FROM stream_events WHERE stream_id = ?1),
               (SELECT count(*) FROM stream_events WHERE stream_id = ?2 AND original_stream_id = ?1)
        """,
        [stream.stream_id, @all_stream_id]
      )

    if stream_rows != stream.stream_version or all_rows != stream.stream_version do
      raise """
      cannot archive #{inspect(stream.stream_id)}: its version is \
      #{stream.stream_version}, but it has #{stream_rows} rows and #{all_rows} \
      rows in $all. Every event must be in its stream and in $all exactly once. \
      Nothing was archived.
      """
    end
  end

  defp insert_archived_stream(repo, stream_id) do
    %{rows: [[archive_id]]} =
      SQL.query!(
        repo,
        """
        INSERT INTO archived_streams (stream_id, stream_version, created_at, archived_at)
        SELECT stream_id, stream_version, inserted_at, strftime('%Y-%m-%dT%H:%M:%S', 'now')
        FROM streams
        WHERE stream_id = ?1
        RETURNING id
        """,
        [stream_id]
      )

    archive_id
  end

  defp copy_to_archive!(repo, archive_id, stream) do
    %{num_rows: copied} =
      SQL.query!(
        repo,
        """
        INSERT INTO archived_stream_events (archive_id, event_id, stream_version, all_position)
        SELECT ?1, s.event_id, s.stream_version, a.stream_version
        FROM stream_events s
        JOIN stream_events a
          ON a.stream_id = ?3
         AND a.original_stream_id = s.stream_id
         AND a.original_stream_version = s.stream_version
         AND a.event_id = s.event_id
        WHERE s.stream_id = ?2
        """,
        [archive_id, stream.stream_id, @all_stream_id]
      )

    if copied != stream.stream_version do
      raise """
      cannot archive #{inspect(stream.stream_id)}: only #{copied} of its \
      #{stream.stream_version} events have a matching $all row. Nothing was \
      archived.
      """
    end
  end

  defp delete_stream(repo, stream_id) do
    SQL.query!(repo, "DELETE FROM stream_events WHERE stream_id = ?2 AND original_stream_id = ?1", [
      stream_id,
      @all_stream_id
    ])

    SQL.query!(repo, "DELETE FROM stream_events WHERE stream_id = ?1", [stream_id])
    SQL.query!(repo, "DELETE FROM streams WHERE stream_id = ?1", [stream_id])
  end
end
