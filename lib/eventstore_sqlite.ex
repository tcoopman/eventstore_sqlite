defmodule EventstoreSqlite do
  @moduledoc false
  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL
  alias EventstoreSqlite.Event
  alias EventstoreSqlite.Reader
  alias EventstoreSqlite.SystemEvents.StreamArchived

  @all_stream_id "$all"
  @archives_stream_id "$archives"
  @system_streams [@all_stream_id, @archives_stream_id]
  @default_count 10_000
  @default_chunk_size 1_000

  # Max events per INSERT statement. Each event binds 5 parameters, so this keeps
  # us comfortably under SQLite's bound-parameter limit (SQLITE_MAX_VARIABLE_NUMBER)
  # for arbitrarily large appends.
  @insert_chunk_size 1_000

  @doc """
  Returns a lazy stream of the events in `stream_id`, oldest first.

  `stream_id` is a stream id, a `{stream_id, start_version}` tuple, or a list of
  either to read several streams interleaved in append order.

  Every event carries `stream_id` / `stream_version` of the stream it was read
  from, and `original_stream_id` / `original_stream_version` of the stream it was
  appended to. They differ only for events read from `"$all"`, whose
  `stream_version` is the event's position in `"$all"`.

  Options:

    * `:count` - stop after this many events. Defaults to no limit: the stream is
      read in chunks, so reading a whole stream does not load it into memory.
    * `:chunk_size` - how many events to fetch per database query (default
      #{@default_chunk_size}). A chunk's raw rows stay in memory until the consumer
      has worked through it, so lower this for streams of large events.
  """
  def stream_forward(stream_id, opts \\ []) do
    {chunk_size, limit} = reader_opts(opts)

    Reader.stream(with_start_versions(stream_id), :asc, chunk_size, limit)
  end

  @doc """
  Returns a lazy stream of the events in `stream_id`, newest first, down to the
  start version if one is given.

  Takes the same `stream_id` shapes and options as `stream_forward/2`.
  """
  def stream_backward(stream_id, opts \\ []) do
    {chunk_size, limit} = reader_opts(opts)

    Reader.stream(with_start_versions(stream_id), :desc, chunk_size, limit)
  end

  @doc """
  Reads the events in `stream_id` into a list, oldest first.

  Takes the same arguments as `stream_forward/2`, except that `:count` defaults to
  #{@default_count}, since the whole result is held in memory. Pass `count: nil`
  to read everything.
  """
  def read_stream_forward(stream_id, opts \\ []) do
    stream_id |> stream_forward(with_default_count(opts)) |> Enum.to_list()
  end

  @doc """
  Reads the events in `stream_id` into a list, newest first.

  Takes the same arguments as `stream_backward/2`, except that `:count` defaults
  to #{@default_count}, as in `read_stream_forward/2`.
  """
  def read_stream_backward(stream_id, opts \\ []) do
    stream_id |> stream_backward(with_default_count(opts)) |> Enum.to_list()
  end

  @doc """
  Appends `events` to `stream_id`.

  Each element of `events` is either a bare event struct, or an
  `EventstoreSqlite.NewEvent` carrying metadata and/or a caller-supplied event
  id. The two shapes can be mixed in one call.

      append_to_stream("scan-42", [
        %TicketScanned{ticket_id: id},
        %EventstoreSqlite.NewEvent{
          data: %BadgePrinted{ticket_id: id},
          metadata: %{correlation_id: flow_id, causation_id: scan_id}
        }
      ])

  `expected_version` guards the append: `:any_version` (the default),
  `:no_stream`, `:stream_exists`, or `{:version, n}`. A mismatch returns
  `{:error, :wrong_expected_version}` and writes nothing.

  `"$all"` and `"$archives"` are maintained by the store itself: appending to
  them returns `{:error, :system_stream}` and writes nothing.

  Supplying your own id lets an event reference a sibling it is appended
  alongside. The id must be a UUID string and must not already exist in the
  store — a malformed id raises `ArgumentError` and a duplicate raises out of the
  write transaction, leaving the whole batch unwritten.
  """
  def append_to_stream(stream_id, events, expected_version \\ :any_version)

  def append_to_stream(stream_id, _events, _) when stream_id in @system_streams, do: {:error, :system_stream}

  def append_to_stream(_stream_id, [], _), do: :ok

  def append_to_stream(stream_id, events, expected_version) when is_binary(stream_id) and is_list(events) do
    events = Enum.map(events, &Event.new(&1))

    case EventstoreSqlite.RepoWrite.transact(
           fn repo ->
             with :ok <- validate_version(repo, stream_id, expected_version),
                  :ok <- insert_events(repo, events),
                  {:ok, written} <- insert_in_stream(repo, stream_id, Enum.map(events, &{&1.id, nil})),
                  {:ok, _} <- insert_in_stream(repo, @all_stream_id, written) do
               {:ok, :done}
             end
           end,
           mode: :immediate
         ) do
      {:ok, _} ->
        :ok = EventstoreSqlite.Subscriptions.ping(stream_id)
        :ok

      {:error, :wrong_expected_version} ->
        {:error, :wrong_expected_version}
    end
  end

  @doc """
  Archives the whole of `stream_id`, so that the store looks as if the stream
  never existed.

  Afterwards no read, `list_streams/0` or `"$all"` returns its events, and the
  name is free again: the next append to `stream_id` starts a new stream at
  version 0. The events themselves are kept in the archive tables, and an
  `EventstoreSqlite.SystemEvents.StreamArchived` event is appended to
  `"$archives"`.

  `expected_version` guards the archive like it guards `append_to_stream/3`.
  Returns `{:error, :stream_not_found}` when the stream doesn't exist,
  `{:error, :wrong_expected_version}` on a version mismatch, and
  `{:error, :system_stream}` for `"$all"` and `"$archives"`. Nothing is archived
  in those cases.

  Subscribers of `stream_id` receive `{:stream_archived, stream_id}` and their
  subscription ends; to follow the new stream of the same name, subscribe again.
  `"$all"` subscribers get no message: the archived events leave gaps in
  `"$all"` positions, and a projection that already processed them learns about
  the archive by subscribing to `"$archives"`.

  Archived events keep their ids, so a later append with a caller-supplied id
  equal to an archived event's id still fails as a duplicate.

  Once a stream has been archived, rolling back to a version of this library
  without archiving is not supported: that version can't see the archive tables
  and treats `"$archives"` as an ordinary stream.
  """
  def archive_stream(stream_id, expected_version \\ :any_version)

  def archive_stream(stream_id, _) when stream_id in @system_streams, do: {:error, :system_stream}

  def archive_stream(stream_id, expected_version) when is_binary(stream_id) do
    EventstoreSqlite.Subscriptions.archive_stream(stream_id, fn ->
      EventstoreSqlite.RepoWrite.transact(&archive_in_transaction(&1, stream_id, expected_version), mode: :immediate)
    end)
  end

  @doc """
  Subscribes `subscriber_pid` to `stream`; events arrive as `{:events, [RecordedEvent.t()]}` messages.

  `version` is the first event version to deliver: `0` (the default) replays the whole
  stream first, and `:current` skips existing history so only events appended after
  subscribing are delivered.

  When `stream` is archived (see `archive_stream/2`), the subscriber receives
  `{:stream_archived, stream}` and the subscription ends. Subscribe again to
  follow the new stream of the same name.

  Options:

    * `:batch_size` - the most events delivered in one `{:events, events}` message
      (default #{@default_count}). A subscriber catching up on history receives it
      as consecutive messages of at most this many events. Subscribers of the same
      stream are served together, so a message can hold fewer events when another
      subscriber of that stream asked for a smaller batch.
  """
  def subscribe_to_stream(subscriber_pid, stream, version \\ 0, filter \\ nil, opts \\ [])
      when is_integer(version) or version == :current do
    batch_size = positive_integer_option!(opts, :batch_size, @default_count)

    EventstoreSqlite.Subscriptions.subscribe_to_stream(subscriber_pid, stream, version, filter, batch_size)
  end

  @doc false
  def system_streams, do: @system_streams

  @doc """
  Lists all streams in the eventstore
  """
  def list_streams do
    query =
      from(stream in "streams",
        select: stream.stream_id,
        order_by: [{:asc, stream.stream_id}]
      )

    EventstoreSqlite.RepoRead.all(query)
  end

  defp validate_version(_repo, _stream_id, :any_version), do: :ok

  defp validate_version(repo, stream_id, expected_version)
       when expected_version == :no_stream or expected_version == {:version, 0} do
    if repo.exists?(from(stream in EventstoreSqlite.Stream, where: stream.stream_id == ^stream_id)) do
      {:error, :wrong_expected_version}
    else
      :ok
    end
  end

  defp validate_version(repo, stream_id, :stream_exists) do
    if repo.exists?(from(stream in EventstoreSqlite.Stream, where: stream.stream_id == ^stream_id)) do
      :ok
    else
      {:error, :wrong_expected_version}
    end
  end

  defp validate_version(repo, stream_id, {:version, version}) do
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

  defp insert_events(repo, events) do
    events
    |> Enum.chunk_every(@insert_chunk_size)
    |> Enum.each(fn chunk ->
      repo.insert_all(Event, Enum.map(chunk, &Map.drop(&1, [:__struct__, :__meta__])))
    end)
  end

  defp with_start_versions(stream_id) when is_binary(stream_id), do: [{stream_id, 0}]

  defp with_start_versions({stream_id, start_version}) when is_binary(stream_id), do: [{stream_id, start_version}]

  defp with_start_versions(stream_ids) when is_list(stream_ids) do
    Enum.flat_map(stream_ids, &with_start_versions/1)
  end

  defp reader_opts(opts) do
    {positive_integer_option!(opts, :chunk_size, @default_chunk_size), Keyword.get(opts, :count)}
  end

  defp with_default_count(opts), do: Keyword.put_new(opts, :count, @default_count)

  defp positive_integer_option!(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      value -> raise ArgumentError, "expected #{inspect(key)} to be a positive integer, got: #{inspect(value)}"
    end
  end

  defp insert_in_stream(repo, stream_id, entries) do
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

  defp archive_in_transaction(repo, stream_id, expected_version) do
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

      {:ok, :archived}
    end
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

  defp append_system_event(repo, stream_id, data) do
    event = Event.new(data)
    :ok = insert_events(repo, [event])
    {:ok, _} = insert_in_stream(repo, stream_id, [{event.id, nil}])
  end
end
