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

    test "returns an empty list when no events match" do
      streams_to_read = [{"non-existent-stream", 0}]

      result =
        streams_to_read
        |> Reader.stream(:asc, 1000)
        |> Enum.to_list()

      assert result == []
    end
  end
end
