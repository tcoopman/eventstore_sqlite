defmodule EventstoreSqlite do
  @moduledoc """
  An append-only, SQLite-backed event store for Elixir event structs.

  Events are appended to named streams. Stream versions are zero-based: the
  first event in a stream has version `0`; a stream containing `n` events has
  next version `n`. Every event appended to an application stream is also
  represented in the system stream `"$all"`.

  ## Quick start

      event = %OrderPlaced{order_id: order_id}

      :ok = EventstoreSqlite.append_to_stream("orders/123", [event], :no_stream)

      [recorded] = EventstoreSqlite.read_stream_forward("orders/123")
      recorded.data
      #=> %OrderPlaced{order_id: order_id}

  Use `stream_forward/2` or `stream_backward/2` when a lazy, chunked read is
  preferable to building a list. Use `subscribe_to_stream/5` to receive new
  events as messages in a process.

  ## Recorded events and ordering

  Reads and subscriptions return `EventstoreSqlite.RecordedEvent` structs; see
  that module for their fields, including how events read from `"$all"` name
  the stream they were appended to.

  Reading several streams merges their rows in database insertion order. If
  the selection includes both an application stream and `"$all"`, an event
  present in both is returned twice—once for each stream row. Forward and
  backward reads use opposite orders. A requested start version is inclusive.

  Archiving a stream removes its live rows, including its rows in `"$all"`.
  Consequently, `"$all"` positions can have gaps after an archive; positions are
  not renumbered or reused. A saved `"$all"` position is a cursor, not an event
  count.

  ## System streams

  `"$all"` contains a row for each live event of an application stream. The
  `"$archives"` stream contains
  `%EventstoreSqlite.SystemEvents.StreamArchived{}` notifications and is created
  on the first archive. Each notification identifies the archived stream and
  archive ID, and gives its event count. Both names are reserved:
  `append_to_stream/3` returns `{:error, :system_stream}` for them. Archive
  notifications are not themselves added to `"$all"`.

  ## Persistence and event data

  Event data and metadata are serialized using Erlang term encoding. Events
  must be Elixir structs; use `EventstoreSqlite.NewEvent` to provide metadata
  or a caller-supplied UUID event ID. Keep event modules and their serialized
  shape compatible with the data already stored in the database.

  ## Public API

    * `append_to_stream/3` — atomically append a batch, optionally guarded by an
      expected stream version.
    * `stream_forward/2`, `stream_backward/2` — lazily read events in chunks.
    * `read_stream_forward/2`, `read_stream_backward/2` — read into a list, with
      a default limit of 10,000 events.
    * `subscribe_to_stream/5` — deliver events and archive notifications to a
      process.
    * `archive_stream/2` — move a whole stream out of the live store while
      retaining its records in archive tables.
    * `list_streams/0` — list live stream names, including system streams that
      currently exist.

  There is no public API to read or unarchive archived events. See
  `archive_stream/2` for why rolling back the library after an archive is not
  supported.
  """
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
  Returns a lazy stream of recorded events, oldest first.

  `stream_id` may be:

    * a stream name, such as `"orders/123"`;
    * `{stream_name, start_version}`, to start at that version (inclusive); or
    * a non-empty list of stream names and/or `{stream_name, start_version}`
      tuples, to merge multiple streams. An empty list raises
      `Enum.EmptyError`.

  For a multi-stream read, rows are ordered by their database insertion order.
  Selecting both an application stream and `"$all"` returns each matching event
  twice, once for each stream row. See `EventstoreSqlite.RecordedEvent` for the
  meaning of `stream_id`, `stream_version`, and the `original_*` fields.

  Options:

    * `:count` — maximum total number of events to emit across all selected
      streams. Defaults to `nil` (no limit).
    * `:chunk_size` — number of rows fetched per database query (default
      #{@default_chunk_size}); it must be a positive integer. The query result
      for one chunk is held in memory while it is consumed; reduce this for very
      large event payloads.

  The stream is lazy: enumeration performs database reads. A read of a stream
  that does not exist emits no events.
  """
  def stream_forward(stream_id, opts \\ []) do
    {chunk_size, limit} = reader_opts(opts)

    Reader.stream(with_start_versions(stream_id), :asc, chunk_size, limit)
  end

  @doc """
  Returns a lazy stream of recorded events, newest first.

  Accepts the same stream selectors and options as `stream_forward/2`. A
  `{stream_name, start_version}` selector sets an inclusive lower bound: events
  newer than that version are emitted first, down through the specified
  version. For a multi-stream read, rows are emitted in reverse database
  insertion order. `:count`, when provided, limits the total number emitted.
  """
  def stream_backward(stream_id, opts \\ []) do
    {chunk_size, limit} = reader_opts(opts)

    Reader.stream(with_start_versions(stream_id), :desc, chunk_size, limit)
  end

  @doc """
  Reads recorded events into a list, oldest first.

  Accepts the same selectors and options as `stream_forward/2`. Unlike
  `stream_forward/2`, `:count` defaults to #{@default_count}, because the result
  is accumulated in memory. Pass `count: nil` to read all matching events.
  """
  def read_stream_forward(stream_id, opts \\ []) do
    stream_id |> stream_forward(with_default_count(opts)) |> Enum.to_list()
  end

  @doc """
  Reads recorded events into a list, newest first.

  Accepts the same selectors and options as `stream_backward/2`. `:count`
  defaults to #{@default_count}, because the result is accumulated in memory.
  Pass `count: nil` to read all matching events.
  """
  def read_stream_backward(stream_id, opts \\ []) do
    stream_id |> stream_backward(with_default_count(opts)) |> Enum.to_list()
  end

  @doc """
  Atomically appends a batch of events to `stream_id` and to the system stream
  `"$all"`.

  Each item must be an event struct or an `%EventstoreSqlite.NewEvent{}`; the
  two forms may be mixed. Use `NewEvent` to attach metadata or choose an event
  ID:

      append_to_stream("scan-42", [
        %TicketScanned{ticket_id: id},
        %EventstoreSqlite.NewEvent{
          data: %BadgePrinted{ticket_id: id},
          metadata: %{correlation_id: flow_id, causation_id: scan_id}
        }
      ])

  The entire batch is one write transaction: a failed append does not leave a
  partial batch. A successful non-empty append returns `:ok`.

  `expected_version` controls which current stream state is accepted:

    * `:any_version` — do not check the current state (default).
    * `:no_stream` — succeed only if the stream does not exist.
    * `:stream_exists` — succeed only if the stream exists.
    * `{:version, n}` — succeed only if the stream's current version is `n`.
      This is the next version / event count, not the last event's version.
      For example, after versions `0..2`, the current value is `3`.
      `{:version, 0}` also succeeds when the stream does not yet exist, like
      `:no_stream`.

  A mismatch returns `{:error, :wrong_expected_version}` and writes nothing.
  `"$all"` and `"$archives"` are reserved; appending to either returns
  `{:error, :system_stream}`. Appending an empty list to an ordinary stream is
  a no-op that returns `:ok` without creating a stream or checking
  `expected_version`.

  Bare event structs receive a generated UUIDv7 ID. A `NewEvent` may supply an
  ID, which must be a UUID string not already present in the store. A malformed
  supplied ID raises `ArgumentError`; a duplicate ID raises from the database
  write and aborts the whole batch. Supplying an ID is useful when one event's
  metadata refers to a sibling event in the same batch.
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
  Archives the complete live stream named `stream_id`.

  The operation copies the stream's event IDs, stream versions, and old
  `"$all"` positions to archive tables, then removes its rows from the live
  stream and from `"$all"`. Event records remain in the database, but there is
  currently no public API to read or unarchive archived data.

  The stream name becomes available for a new stream. A later append with
  `:no_stream` starts that new stream at version `0`; archiving the reused name
  again creates a separate archive record with a new `archive_id`.

  The operation also appends an
  `%EventstoreSqlite.SystemEvents.StreamArchived{}` event to `"$archives"`.
  It is not added to `"$all"`. Existing `"$archives"` subscribers receive it;
  subscribers to the archived stream receive `{:stream_archived, stream_id}`
  and are unsubscribed. Events appended before the archive that had not yet
  been delivered to them are not delivered: the archive message is the last
  thing they receive for that stream. They must subscribe again to follow a new
  stream with that name. `"$all"` subscribers receive no archive notification;
  their positions can have gaps, and projections that already processed the
  removed events must use `"$archives"` to learn about the archive.

  `expected_version` uses the same rules as `append_to_stream/3` and is checked
  against the live stream. Because a missing stream returns
  `{:error, :stream_not_found}` before the version is checked, `:no_stream` and
  `{:version, 0}` never succeed. The result is:

    * `:ok` — the archive committed;
    * `{:error, :stream_not_found}` — no live stream has that name;
    * `{:error, :wrong_expected_version}` — the expected state did not match;
    * `{:error, :system_stream}` — `stream_id` is `"$all"` or `"$archives"`.

  These returned errors leave the store unchanged. An integrity inconsistency
  (for example, a stream row whose event rows do not match its recorded version)
  raises and rolls back the transaction rather than archiving incomplete data.

  Archived event IDs remain globally reserved, so a caller-supplied ID from an
  archived event cannot be reused. Once any stream has been archived, rolling
  back to a library version without archive support is not supported; that
  version cannot see the archive tables and treats `"$archives"` as an ordinary
  stream.

  The archive runs inside the subscription process, so that subscription cursors
  change in order with it. This call waits, without a timeout, until the archive
  has finished, and no subscriber receives events while it runs.
  """
  def archive_stream(stream_id, expected_version \\ :any_version)

  def archive_stream(stream_id, _) when stream_id in @system_streams, do: {:error, :system_stream}

  def archive_stream(stream_id, expected_version) when is_binary(stream_id) do
    EventstoreSqlite.Subscriptions.archive_stream(stream_id, fn ->
      EventstoreSqlite.RepoWrite.transact(&archive_in_transaction(&1, stream_id, expected_version), mode: :immediate)
    end)
  end

  @doc """
  Subscribes a process to a stream. Returns `:ok` after registering the
  subscription. The subscriber receives messages of the form
  `{:events, [recorded_event]}` where each item is an
  `EventstoreSqlite.RecordedEvent`.

  `version` is the first stream version to deliver:

    * `0` (default) replays all currently available history, then follows new
      appends;
    * a non-negative integer starts at that version, inclusive;
    * `:current` skips the history present when the subscription is registered
      and follows later events. For a stream that does not exist yet,
      `:current` behaves like version `0`.

  When the stream is archived, the process receives
  `{:stream_archived, stream_id}` and that subscription ends; events appended
  before the archive that had not been delivered yet are not delivered.
  Subscribe again to follow a new stream with the same name. A `"$all"`
  subscriber is not sent this message; archived events simply disappear from
  future reads, leaving position gaps. Subscribe to `"$archives"` to receive
  archive notifications.
  Subscriber processes are monitored; their registrations are removed when
  they terminate. There is no separate unsubscribe function. Archive
  transactions run through the subscription process to keep cursor changes
  ordered; a large archive can temporarily delay delivery processing for other
  subscriptions.

  Options:

    * `:batch_size` — maximum number of events in one `{:events, events}`
      message (default #{@default_count}); it must be a positive integer.
      Catch-up history is delivered in consecutive batches. Subscribers to the
      same stream are served together using the smallest requested batch size,
      so a subscriber may receive fewer events per message than its own limit.

  `filter` is retained as an argument for compatibility but is currently not
  applied; pass `nil` unless using a version that implements filtering.
  """
  def subscribe_to_stream(subscriber_pid, stream, version \\ 0, filter \\ nil, opts \\ [])
      when is_integer(version) or version == :current do
    batch_size = positive_integer_option!(opts, :batch_size, @default_count)

    EventstoreSqlite.Subscriptions.subscribe_to_stream(subscriber_pid, stream, version, filter, batch_size)
  end

  @doc false
  def system_streams, do: @system_streams

  @doc """
  Returns the names of all currently live streams, sorted lexicographically.

  `"$all"` appears after the first event has been appended. `"$archives"`
  appears after the first stream has been archived. Archived application stream
  names do not appear; a name may reappear if a new live stream is created with
  that name.
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
