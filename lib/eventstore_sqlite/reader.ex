defmodule EventstoreSqlite.Reader do
  @moduledoc false
  import Ecto.Query, only: [from: 2, dynamic: 2]

  alias EventstoreSqlite.Event

  @doc """
  Returns a lazy stream of events in chunks, stopping after a total maximum limit.

  - `stream_ids_with_start_version`: A list of tuples, e.g., `[{"stream-A", 0}]`.
  - `asc_or_desc`: The order of events, `:asc` or `:desc`.
  - `chunk_size`: The number of events to fetch from the database in each batch.
  - `max_limit`: An optional integer. The stream will stop after emitting this
    many total events. If `nil`, it will stream until the end.
  """
  def stream(stream_ids_with_start_version, asc_or_desc, chunk_size, max_limit \\ nil)
      when asc_or_desc in [:asc, :desc] and is_integer(chunk_size) and chunk_size > 0 do
    initial_state = {nil, 0}

    initial_state
    |> Stream.unfold(fn
      {cursor, count_so_far} ->
        if max_limit && count_so_far >= max_limit do
          nil
        else
          limit_for_query =
            if max_limit do
              min(chunk_size, max_limit - count_so_far)
            else
              chunk_size
            end

          raw_chunk =
            fetch_chunk(stream_ids_with_start_version, asc_or_desc, limit_for_query, cursor)

          if raw_chunk == [] do
            nil
          else
            next_cursor = List.last(raw_chunk).stream_event_id
            new_count = count_so_far + length(raw_chunk)

            next_state = {next_cursor, new_count}

            parsed_chunk =
              Stream.map(raw_chunk, fn event_map ->
                EventstoreSqlite.RecordedEvent.parse(
                  event_map.id,
                  event_map.type,
                  event_map.stream_id,
                  event_map.data,
                  event_map.created,
                  event_map.stream_version
                )
              end)

            {parsed_chunk, next_state}
          end
        end
    end)
    |> Stream.flat_map(& &1)
  end

  defp fetch_chunk(stream_ids_with_start_version, asc_or_desc, limit, cursor) do
    where_streams =
      stream_ids_with_start_version
      |> Enum.map(fn {stream_id, start_version} ->
        dynamic([s], s.stream_id == ^stream_id and s.stream_version >= ^start_version)
      end)
      |> Enum.reduce(fn s, acc -> dynamic([], ^s or ^acc) end)

    query = from(s in "stream_events", where: ^where_streams)

    query =
      if cursor do
        cursor_where =
          case asc_or_desc do
            :asc -> dynamic([s], s.id > ^cursor)
            :desc -> dynamic([s], s.id < ^cursor)
          end

        from([s] in query, where: ^cursor_where)
      else
        query
      end

    final_query =
      from(s in query,
        join: event in Event,
        on: s.event_id == event.id,
        select: %{
          stream_event_id: s.id,
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

    EventstoreSqlite.RepoRead.all(final_query)
  end
end
