defmodule EventstoreSqlite do
  @moduledoc false
  import Ecto.Query, only: [from: 2]

  alias EventstoreSqlite.Event
  alias EventstoreSqlite.Reader

  @all_stream_id "$all"
  @system_streams [@all_stream_id]
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

  `"$all"` is maintained by the store itself: appending to it returns
  `{:error, :system_stream}` and writes nothing.

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
  Subscribes `subscriber_pid` to `stream`; events arrive as `{:events, [RecordedEvent.t()]}` messages.

  `version` is the first event version to deliver: `0` (the default) replays the whole
  stream first, and `:current` skips existing history so only events appended after
  subscribing are delivered.

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

      Ecto.Adapters.SQL.query!(repo, query, params)
    end)

    {:ok, Enum.map(rows, fn {event_id, version, _origin} -> {event_id, {stream_id, version}} end)}
  end
end
