defmodule EventstoreSqlite.ReaderTest do
  use EventstoreSqlite.DataCase
  use TypedStruct

  alias EventstoreSqlite.Reader

  @moduletag :capture_log

  @total_events 25
  @stream_id "test-stream-123"

  typedstruct module: FooTestEvent do
    field(:text, :string)
  end

  setup do
    events =
      for i <- 1..@total_events do
        %FooTestEvent{
          text: "event: #{i}"
        }
      end

    assert :ok = EventstoreSqlite.append_to_stream(@stream_id, events)

    {:ok, all_events: events}
  end

  describe "stream_events_in_chunks/4" do
    test "fails on chunk size of 0" do
      chunk_size = 0
      streams_to_read = [{@stream_id, 0}]

      assert_raise FunctionClauseError, fn ->
        Reader.stream(streams_to_read, :asc, chunk_size)
      end
    end

    test "returns all events in ascending chunks when total is not a multiple of chunk size", %{
      all_events: all_events
    } do
      chunk_size = 10
      streams_to_read = [{@stream_id, 0}]

      result_chunks =
        streams_to_read
        |> Reader.stream(:asc, chunk_size)
        |> Enum.to_list()

      all_returned_events = List.flatten(result_chunks)

      assert length(all_returned_events) == @total_events
      assert Enum.map(all_returned_events, & &1.data) == all_events
    end

    test "returns all events in descending chunks", %{all_events: all_events} do
      chunk_size = 8
      streams_to_read = [{@stream_id, 0}]

      result_chunks =
        streams_to_read
        |> Reader.stream(:desc, chunk_size)
        |> Enum.to_list()

      all_returned_events = List.flatten(result_chunks)
      assert length(all_returned_events) == @total_events

      expected_events = Enum.reverse(all_events)
      assert Enum.map(all_returned_events, & &1.data) == expected_events
    end

    test "returns one chunk when chunk size is larger than total events" do
      # Much larger than @total_events (25)
      chunk_size = 100
      streams_to_read = [{@stream_id, 0}]

      result_chunks =
        streams_to_read
        |> Reader.stream(:asc, chunk_size)
        |> Enum.to_list()

      assert length(result_chunks) == @total_events
    end

    test "a single-stream read lets SQLite stop at the limit instead of sorting the whole stream" do
      for direction <- [:asc, :desc], cursor? <- [false, true] do
        plan =
          query_plan(fn -> [{@stream_id, 3}] |> Reader.stream(direction, 5) |> Enum.take(if cursor?, do: 6, else: 1) end)

        assert plan =~ "stream_events_stream_id_stream_version_index"
        refute plan =~ "TEMP B-TREE", "#{direction} read sorts: #{plan}"
      end
    end

    test "returns an empty list when no events match" do
      streams_to_read = [{"non-existent-stream", 0}]

      result =
        streams_to_read
        |> Reader.stream(:asc, 1000)
        |> Enum.to_list()

      assert result == []
    end

    test "a single-stream read from a start version pages through every chunk in order" do
      for direction <- [:asc, :desc], chunk_size <- [1, 3, 7] do
        versions = [{@stream_id, 4}] |> Reader.stream(direction, chunk_size) |> Enum.map(& &1.stream_version)

        expected = if direction == :asc, do: Enum.to_list(4..24), else: Enum.to_list(24..4//-1)
        assert versions == expected
      end
    end
  end

  defp query_plan(read) do
    handler = "query-plan-#{System.unique_integer()}"
    test_pid = self()

    :telemetry.attach(
      handler,
      [:eventstore_sqlite, :repo_read, :query],
      fn _, _, meta, _ ->
        if meta.query =~ "stream_events", do: send(test_pid, {:query, meta.query, meta.params})
      end,
      nil
    )

    try do
      read.()
    after
      :telemetry.detach(handler)
    end

    queries = collect_queries([])
    assert queries != []

    Enum.map_join(queries, "\n", fn {sql, params} ->
      %{rows: rows} = Ecto.Adapters.SQL.query!(EventstoreSqlite.RepoRead, "EXPLAIN QUERY PLAN " <> sql, params)
      Enum.map_join(rows, "\n", &List.last/1)
    end)
  end

  defp collect_queries(acc) do
    receive do
      {:query, sql, params} -> collect_queries([{sql, params} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
