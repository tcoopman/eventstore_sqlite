defmodule EventstoreSqlite do
  import Ecto.Query, only: [from: 2]

  alias EventstoreSqlite.{Stream}
  alias EventstoreSqlite.Event

  @all_stream_id "$all"

  def read_stream_forward(stream_id, opts \\ []) when is_binary(stream_id) do
    limit = Keyword.get(opts, :count, 100)
    start_version = Keyword.get(opts, :start_version, 0)

    query =
      from(s in "stream_events",
        where: s.stream_id == ^stream_id and s.stream_version >= ^start_version,
        join: event in Event,
        on: s.event_id == event.id,
        select: %{id: event.id, type: event.type, data: event.data},
        limit: ^limit
      )

    EventstoreSqlite.Repo.all(query)
    |> Enum.map(fn event ->
      parse_event(event)
    end)
  end

  def append_to_stream(_stream_id, []), do: :ok

  def append_to_stream(stream_id, events) when is_binary(stream_id) and is_list(events) do
    events = Enum.map(events, &Event.new(&1))

    {:ok, _} =
      Ecto.Multi.new()
      |> insert_events(events)
      |> insert_in_stream(stream_id)
      |> insert_in_stream(@all_stream_id)
      |> EventstoreSqlite.Repo.transaction()

    :ok
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

  defp insert_events(multi, events) do
    multi
    |> Ecto.Multi.insert_all(
      :insert_events,
      Event,
      fn _ -> Enum.map(events, &Map.drop(&1, [:__struct__, :__meta__])) end,
      returning: [:id]
    )
  end

  defp parse_event(event) do
    EventstoreSqlite.RecordedEvent.parse(event.id, event.type, event.data)
  end
end
