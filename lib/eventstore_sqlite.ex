defmodule EventstoreSqlite do
  @moduledoc false
  import Ecto.Query, only: [from: 2]

  alias EventstoreSqlite.Event
  alias EventstoreSqlite.Reader

  @all_stream_id "$all"
  @default_count 10_000
  @default_chunk_size 1_000

  def stream_forward(stream_id, opts \\ [])

  def stream_forward(stream_id, opts) when is_binary(stream_id) do
    limit = Keyword.get(opts, :count, @default_count)

    Reader.stream([{stream_id, 0}], :asc, @default_chunk_size, limit)
  end

  def stream_forward({stream_id, start_version}, opts) when is_binary(stream_id) do
    limit = Keyword.get(opts, :count, @default_count)

    Reader.stream([{stream_id, start_version}], :asc, @default_chunk_size, limit)
  end

  def stream_forward(stream_ids, opts) when is_list(stream_ids) do
    limit = Keyword.get(opts, :count, @default_count)

    stream_ids_with_version =
      Enum.map(stream_ids, fn
        {stream_id, start_version} -> {stream_id, start_version}
        stream_id -> {stream_id, 0}
      end)

    Reader.stream(stream_ids_with_version, :asc, @default_chunk_size, limit)
  end

  def stream_backward(stream_id, opts \\ [])

  def stream_backward(stream_id, opts) when is_binary(stream_id) do
    limit = Keyword.get(opts, :count, @default_count)

    Reader.stream([{stream_id, 0}], :desc, @default_chunk_size, limit)
  end

  def stream_backward(stream_ids, opts) when is_list(stream_ids) do
    limit = Keyword.get(opts, :count, @default_count)

    stream_ids_with_version =
      Enum.map(stream_ids, fn
        stream_id -> {stream_id, 0}
      end)

    Reader.stream(stream_ids_with_version, :desc, @default_chunk_size, limit)
  end

  def read_stream_forward(stream_id, opts \\ []) do
    stream_id |> stream_forward(opts) |> Enum.to_list()
  end

  def read_stream_backward(stream_id, opts) when is_binary(stream_id) do
    stream_id |> stream_backward(opts) |> Enum.to_list()
  end

  def append_to_stream(stream_id, events, expected_version \\ :any_version)

  def append_to_stream(_stream_id, [], _), do: :ok

  def append_to_stream(stream_id, events, expected_version) when is_binary(stream_id) and is_list(events) do
    events = Enum.map(events, &Event.new(&1))

    case Ecto.Multi.new()
         |> validate_version(stream_id, expected_version)
         |> insert_events(events)
         |> insert_in_stream(stream_id)
         |> insert_in_stream(@all_stream_id)
         |> EventstoreSqlite.RepoWrite.transaction(mode: :immediate) do
      {:ok, _} ->
        :ok = EventstoreSqlite.Subscriptions.ping(stream_id)

        :ok

      {:error, _, :wrong_expected_version, _} ->
        {:error, :wrong_expected_version}
    end
  end

  def subscribe_to_stream(subscriber_pid, stream, version \\ 0, filter \\ nil) do
    EventstoreSqlite.Subscriptions.subscribe_to_stream(subscriber_pid, stream, version, filter)
  end

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

  defp validate_version(multi, _stream_id, :any_version) do
    multi
  end

  defp validate_version(multi, stream_id, expected_version)
       when expected_version == :no_stream or expected_version == {:version, 0} do
    Ecto.Multi.run(multi, {:validate_version, stream_id}, fn repo, _changes ->
      if repo.exists?(from(stream in EventstoreSqlite.Stream, where: stream.stream_id == ^stream_id)) do
        {:error, :wrong_expected_version}
      else
        {:ok, nil}
      end
    end)
  end

  defp validate_version(multi, stream_id, :stream_exists) do
    Ecto.Multi.run(multi, {:validate_version, stream_id}, fn repo, _changes ->
      if repo.exists?(from(stream in EventstoreSqlite.Stream, where: stream.stream_id == ^stream_id)) do
        {:ok, nil}
      else
        {:error, :wrong_expected_version}
      end
    end)
  end

  defp validate_version(multi, stream_id, {:version, version}) do
    Ecto.Multi.run(multi, {:validate_version, stream_id}, fn repo, _changes ->
      if repo.exists?(
           from(stream in EventstoreSqlite.Stream,
             where: stream.stream_id == ^stream_id and stream.stream_version == ^version
           )
         ) do
        {:ok, nil}
      else
        {:error, :wrong_expected_version}
      end
    end)
  end

  defp insert_events(multi, events) do
    Ecto.Multi.insert_all(
      multi,
      :insert_events,
      Event,
      fn _ -> Enum.map(events, &Map.drop(&1, [:__struct__, :__meta__])) end,
      returning: [:id]
    )
  end

  defp insert_in_stream(multi, stream_id) do
    multi
    |> Ecto.Multi.run({:stream, stream_id}, fn repo, _changes ->
      {:ok,
       repo.one(from(stream in EventstoreSqlite.Stream, where: stream.stream_id == ^stream_id)) ||
         %EventstoreSqlite.Stream{stream_id: stream_id, stream_version: 0}}
    end)
    |> Ecto.Multi.insert_or_update({:insert_stream, stream_id}, fn %{
                                                                     :insert_events => {_, events},
                                                                     {:stream, ^stream_id} => stream
                                                                   } ->
      case stream.id do
        nil ->
          Ecto.Changeset.change(stream, stream_version: Enum.count(events))

        _ ->
          Ecto.Changeset.change(stream,
            stream_version: stream.stream_version + Enum.count(events)
          )
      end
    end)
    |> Ecto.Multi.run({:stream_events, stream_id}, fn repo,
                                                      %{
                                                        {:stream, ^stream_id} => stream,
                                                        :insert_events => {_, events}
                                                      } ->
      values =
        events
        |> Enum.with_index(fn event, index ->
          "(#{index}, '#{event.id}')"
        end)
        |> Enum.join(",")

      query = ~s"""
      WITH events (idx, event_id) AS ( VALUES #{values} )
        INSERT INTO stream_events (
          event_id, stream_id, stream_version, original_stream_id, original_stream_version
        )
        SELECT
          events.event_id, '#{stream_id}', $1::integer + events.idx, '#{stream_id}', $1::integer + events.idx
        FROM events
        RETURNING 1
      """

      Ecto.Adapters.SQL.query(repo, query, [stream.stream_version])
    end)
  end
end
