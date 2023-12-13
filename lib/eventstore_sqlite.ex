defmodule EventstoreSqlite do
  import Ecto.Query, only: [from: 2, dynamic: 2]

  alias EventstoreSqlite.{Stream}
  alias EventstoreSqlite.Event

  @all_stream_id "$all"

  def read_stream_forward(stream_id, opts \\ [])

  def read_stream_forward(stream_id, opts) when is_binary(stream_id) do
    limit = Keyword.get(opts, :count, 10_000)

    read_streams_in_direction([{stream_id, 0}], :asc, limit)
  end

  def read_stream_forward({stream_id, start_version}, opts) when is_binary(stream_id) do
    limit = Keyword.get(opts, :count, 10_000)

    read_streams_in_direction([{stream_id, start_version}], :asc, limit)
  end

  def read_stream_forward(stream_ids, opts) when is_list(stream_ids) do
    limit = Keyword.get(opts, :count, 10_000)

    stream_ids_with_version =
      Enum.map(stream_ids, fn
        {stream_id, start_version} -> {stream_id, start_version}
        stream_id -> {stream_id, 0}
      end)

    read_streams_in_direction(stream_ids_with_version, :asc, limit)
  end

  def read_stream_backward(stream_id, opts \\ [])

  def read_stream_backward(stream_id, opts) when is_binary(stream_id) do
    limit = Keyword.get(opts, :count, 10000)

    read_streams_in_direction([{stream_id, 0}], :desc, limit)
  end

  def read_stream_backward(stream_ids, opts) when is_list(stream_ids) do
    limit = Keyword.get(opts, :count, 10000)

    stream_ids_with_version =
      Enum.map(stream_ids, fn
        stream_id -> {stream_id, 0}
      end)

    read_streams_in_direction(stream_ids_with_version, :desc, limit)
  end

  def append_to_stream(stream_id, events, expected_version \\ :any_version)

  def append_to_stream(_stream_id, [], _), do: :ok

  def append_to_stream(stream_id, events, expected_version)
      when is_binary(stream_id) and is_list(events) do
    events = Enum.map(events, &Event.new(&1))

    with {:ok, _} <-
           Ecto.Multi.new()
           |> validate_version(stream_id, expected_version)
           |> insert_events(events)
           |> insert_in_stream(stream_id)
           |> insert_in_stream(@all_stream_id)
           |> EventstoreSqlite.Repo.transaction() do
      :ok
    else
      {:error, _, :wrong_expected_version, _} -> {:error, :wrong_expected_version}
    end
  end

  defp validate_version(multi, _stream_id, :any_version) do
    multi
  end

  defp validate_version(multi, stream_id, expected_version)
       when expected_version == :no_stream or expected_version == {:version, 0} do
    multi
    |> Ecto.Multi.run({:validate_version, stream_id}, fn repo, _changes ->
      unless repo.exists?(from(stream in Stream, where: stream.stream_id == ^stream_id)) do
        {:ok, nil}
      else
        {:error, :wrong_expected_version}
      end
    end)
  end

  defp validate_version(multi, stream_id, :stream_exists) do
    multi
    |> Ecto.Multi.run({:validate_version, stream_id}, fn repo, _changes ->
      if repo.exists?(from(stream in Stream, where: stream.stream_id == ^stream_id)) do
        {:ok, nil}
      else
        {:error, :wrong_expected_version}
      end
    end)
  end

  defp validate_version(multi, stream_id, {:version, version}) do
    multi
    |> Ecto.Multi.run({:validate_version, stream_id}, fn repo, _changes ->
      if repo.exists?(
           from(stream in Stream,
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
    multi
    |> Ecto.Multi.insert_all(
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
       repo.one(from(stream in Stream, where: stream.stream_id == ^stream_id)) ||
         %Stream{stream_id: stream_id, stream_version: 0}}
    end)
    |> Ecto.Multi.insert_or_update({:insert_stream, stream_id}, fn %{
                                                                     :insert_events =>
                                                                       {_, events},
                                                                     {:stream, ^stream_id} =>
                                                                       stream
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

  defp read_streams_in_direction(stream_ids_with_start_version, asc_or_desc, limit) do
    where_conditions =
      Enum.map(stream_ids_with_start_version, fn {stream_id, start_version} ->
        dynamic([s], s.stream_id == ^stream_id and s.stream_version >= ^start_version)
      end)
      |> Enum.reduce(fn s, acc -> dynamic([], ^s or ^acc) end)

    query =
      from(s in "stream_events",
        where: ^where_conditions,
        join: event in Event,
        on: s.event_id == event.id,
        select: %{
          id: event.id,
          type: event.type,
          data: event.data,
          created: event.inserted_at,
          stream_id: s.stream_id,
          stream_version: s.stream_version
        },
        limit: ^limit,
        order_by: [{^asc_or_desc, s.id}]
      )

    EventstoreSqlite.Repo.all(query)
    |> Enum.map(fn event ->
      EventstoreSqlite.RecordedEvent.parse(
        event.id,
        event.type,
        event.stream_id,
        event.data,
        event.created,
        event.stream_version
      )
    end)
  end
end
