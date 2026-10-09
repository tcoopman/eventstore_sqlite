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
  or a caller-supplied UUID event ID. A stored event keeps its struct's module
  name and the fields it was written with; configure an
  `EventstoreSqlite.Upcaster` to read events whose module has since moved or
  whose shape has since changed.

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
    * `stream_info/1`, `list_stream_infos/1` — a stream's version, first and
      last event times and owner, without reading its events; the list is
      searchable and paged.
    * `subscribe_to_changes/1` — be told, at most about once a second, that
      the streams or the sync status changed.

  There is no public API to read or unarchive archived events. See
  `archive_stream/2` for why rolling back the library after an archive is not
  supported.
  """
  import Ecto.Query, only: [from: 2]

  alias EventstoreSqlite.Changes
  alias EventstoreSqlite.Event
  alias EventstoreSqlite.Reader
  alias EventstoreSqlite.Store
  alias EventstoreSqlite.Sync

  @all_stream_id "$all"
  @archives_stream_id "$archives"
  @system_streams [@all_stream_id, @archives_stream_id, "$sync", "$ownership"]
  @default_count 10_000
  @default_chunk_size 1_000
  @default_page_size 100

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

  Once sync is enabled (`EventstoreSqlite.Sync`), an append to a stream this
  node doesn't own returns `{:error, :not_owner}`, and every append on a
  diverged node returns `{:error, :diverged}`. Checking this costs every append
  a read of the sync state, also with sync disabled (see "Cost" in
  `EventstoreSqlite.Sync`).
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
             with {:ok, sync} <- Sync.Write.authorize(repo, stream_id),
                  :ok <- Store.validate_version(repo, stream_id, expected_version),
                  :ok <- Store.insert_events(repo, events) do
               event_ids = Enum.map(events, & &1.id)
               {:ok, first_version} = Store.append_to_stream_and_all(repo, stream_id, event_ids)
               :ok = Sync.Write.log_append(repo, sync, stream_id, first_version, event_ids)
               {:ok, sync}
             end
           end,
           mode: :immediate
         ) do
      {:ok, sync} ->
        :ok = EventstoreSqlite.Subscriptions.ping(stream_id)
        Changes.notify(changed_by_write(sync))
        Sync.Write.notify(sync)

      {:error, reason} ->
        {:error, reason}
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
    archive = fn ->
      EventstoreSqlite.RepoWrite.transact(
        fn repo ->
          with {:ok, sync} <- Sync.Write.authorize(repo, stream_id),
               {:ok, event_count} <- Store.archive_in_transaction(repo, stream_id, expected_version) do
            :ok = Sync.Write.log_archive(repo, sync, stream_id, event_count)
            {:ok, sync}
          end
        end,
        mode: :immediate
      )
    end

    case EventstoreSqlite.Subscriptions.archive_stream(stream_id, archive) do
      {:ok, sync} ->
        Changes.notify(changed_by_write(sync))
        Sync.Write.notify(sync)

      error ->
        error
    end
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

  Events are pushed when an append or import notifies the subscription
  process. As a safety net for a notification that never came (the appending
  process died right after its commit), the subscription process also checks
  once a second whether events were written since its last check, and if so,
  whether any subscribed stream has undelivered events. On an idle store that
  costs one primary-key read per second. Change the interval with
  `config :eventstore_sqlite, subscription_reconcile_interval: ms`.

  Subscriber processes are monitored; their registrations are removed when
  they terminate. There is no separate unsubscribe function. Archive
  transactions run through the subscription process to keep cursor changes
  ordered; a large archive can temporarily delay delivery processing for other
  subscriptions.

  ## When the subscription process stops

  Every subscription is held by one process, `EventstoreSqlite.Subscriptions`.
  If it crashes (for example because an upcaster raised on an event it was
  delivering), its supervisor restarts it **without any subscriptions**, and
  subscribers are not told. A subscriber that doesn't watch for this silently
  stops receiving events.

  So every subscriber must monitor `EventstoreSqlite.Subscriptions` itself and
  subscribe again when it goes down:

      def init(stream) do
        {:ok, subscribe(%{stream: stream, version: 0})}
      end

      defp subscribe(state) do
        ref = Process.monitor(EventstoreSqlite.Subscriptions)
        :ok = EventstoreSqlite.subscribe_to_stream(self(), state.stream, state.version)
        Map.put(state, :ref, ref)
      end

      def handle_info({:events, events}, state) do
        # handle events, skipping versions already handled
        {:noreply, %{state | version: List.last(events).stream_version + 1}}
      end

      def handle_info({:DOWN, ref, :process, _pid, _reason}, %{ref: ref} = state) do
        Process.send_after(self(), :resubscribe, 100)
        {:noreply, state}
      end

      def handle_info(:resubscribe, state) do
        {:noreply, subscribe(state)}
      catch
        :exit, _not_restarted_yet ->
          Process.send_after(self(), :resubscribe, 100)
          {:noreply, state}
      end

  Get these right:

    * **Monitor before subscribing.** Subscribing first leaves a moment in
      which a crash goes unnoticed: the monitor would then watch the restarted
      process, which doesn't hold the subscription.
    * **Don't resubscribe at once on `:DOWN`.** The supervisor may not have
      restarted the process yet, and the call then exits. Wait, and retry when
      it does.
    * **Resubscribe from your own position:** the version after the last event
      you handled, not the one you subscribed with. Events that were in flight
      during the crash may arrive again, so handle a version you have already
      seen as a duplicate.
    * **The process that must monitor is the subscriber**, the one receiving
      `{:events, _}`. When one process subscribes another (`subscriber_pid`
      isn't `self()`), the monitor has to be set up by the subscriber, or
      the `:DOWN` message reaches a process that doesn't hold the subscription.

  Subscribe processes on the same node as the store. A subscriber on another
  node loses its subscription when the connection between the nodes drops,
  and this monitor doesn't cover that.

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

  @doc """
  Tells `subscriber_pid` when the store changes, without saying how. Meant for
  views of the store, such as a dashboard, that reload what they show instead
  of following events.

  The subscriber receives `{:eventstore_sqlite, :changed, kinds}`, where
  `kinds` is a sorted, non-empty list of:

    * `:streams` — a stream was appended to or archived, here or by an import
      from a peer, or ownership changed, so `stream_info/1` and
      `list_stream_infos/1` may return something new;
    * `:sync` — something `EventstoreSqlite.Sync.status/0` returns may have
      changed: the sync state, the change log, a peer's cursor or
      acknowledgement, or a replicator's connection or last error.

  Messages are coalesced per subscriber: the first change is sent at once,
  and changes during the next second are sent together when it ends. A busy
  store therefore sends about one message a second. Change the interval with
  `config :eventstore_sqlite, changes_interval: ms`.

  Notifications are best-effort hints, like `subscribe_to_stream/5`'s pings:

    * they only cover changes made by this node, including what it imports
      from its peers. Another BEAM writing to the same database file sends
      nothing, so poll now and then as well;
    * the subscription ends when the subscriber exits, or when the
      `EventstoreSqlite.Changes` process restarts. Monitor that process and
      subscribe again when it goes down, as described for
      `subscribe_to_stream/5`.

  Subscribing a process twice has no extra effect. Returns `:ok`.
  """
  def subscribe_to_changes(subscriber_pid) when is_pid(subscriber_pid), do: Changes.subscribe(subscriber_pid)

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

  @doc """
  What the store knows about the live stream `stream_id`, without reading its
  events: its version, when its first and last events were appended, and with
  sync enabled its owner. See `EventstoreSqlite.StreamInfo`.

  Returns `{:ok, %EventstoreSqlite.StreamInfo{}}`, or `{:error, :not_found}`
  when no live stream has that name. System streams have info too.
  """
  def stream_info(stream_id) when is_binary(stream_id) do
    case stream_infos([{"s.stream_id = ?", [stream_id]}], 1) do
      [info] -> {:ok, info}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  One page of live streams, ordered by name, each as an
  `EventstoreSqlite.StreamInfo`.

  Options:

    * `:search` — only streams whose name contains this text, ignoring the
      case of ASCII letters. `%`, `_` and `\\` match themselves. Every stream
      name is checked, so on a large store a search costs a scan of the names.
    * `:after` — the page starts after this stream name. Pass the previous
      page's `next`.
    * `:limit` — the most streams on a page (default #{@default_page_size}); it
      must be a positive integer.
    * `:system` — also list the system streams that exist (default `false`).

  Returns `%{entries: [stream_info], next: stream_id | nil}`, where `next` is
  `nil` on the last page. Pages are cut by name, not by position, so a stream
  created or archived while you page is listed or skipped according to where
  its name sorts, and no other stream is listed twice or skipped.
  """
  def list_stream_infos(opts \\ []) do
    limit = positive_integer_option!(opts, :limit, @default_page_size)

    conditions =
      Enum.reject(
        [
          if(!Keyword.get(opts, :system, false), do: not_system_condition()),
          search_condition(Keyword.get(opts, :search)),
          if(after_name = Keyword.get(opts, :after), do: {"s.stream_id > ?", [after_name]})
        ],
        &is_nil/1
      )

    infos = stream_infos(conditions, limit + 1)

    if length(infos) > limit do
      entries = Enum.take(infos, limit)
      %{entries: entries, next: List.last(entries).stream_id}
    else
      %{entries: infos, next: nil}
    end
  end

  defp stream_infos(conditions, limit) do
    rows = Store.stream_rows(EventstoreSqlite.RepoRead, conditions, limit)
    sync = Sync.State.load(EventstoreSqlite.RepoRead)

    Enum.map(rows, fn [stream_id, version, created_at, last_event_at] ->
      %EventstoreSqlite.StreamInfo{
        stream_id: stream_id,
        version: version,
        created_at: timestamp(created_at),
        last_event_at: timestamp(last_event_at),
        owner: if(sync.enabled and stream_id not in @system_streams, do: Sync.State.owner(sync, stream_id))
      }
    end)
  end

  defp not_system_condition do
    {"s.stream_id NOT IN (#{Enum.map_join(@system_streams, ", ", fn _ -> "?" end)})", @system_streams}
  end

  defp search_condition(nil), do: nil
  defp search_condition(""), do: nil

  defp search_condition(text) when is_binary(text) do
    escaped = String.replace(text, ["\\", "%", "_"], &("\\" <> &1))
    {"s.stream_id LIKE ? ESCAPE '\\'", ["%" <> escaped <> "%"]}
  end

  defp timestamp(nil), do: nil

  defp timestamp(text) do
    {:ok, datetime, 0} = DateTime.from_iso8601(text)
    datetime
  end

  defp changed_by_write(:disabled), do: [:streams]
  defp changed_by_write(_sync), do: [:streams, :sync]

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
end
