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

      # The function returns a stream of chunks. Let's realize it into a list of lists.
      result_chunks =
        Reader.stream(streams_to_read, :asc, chunk_size)
        |> Enum.to_list()

      # Assertions for the chunks themselves
      assert length(result_chunks) == 3 # 10 + 10 + 5 = 25
      assert length(Enum.at(result_chunks, 0)) == 10
      assert length(Enum.at(result_chunks, 1)) == 10
      assert length(Enum.at(result_chunks, 2)) == 5

      # Flatten the chunks to get all returned events in order
      all_returned_events = List.flatten(result_chunks)

      # Assert that the total count is correct
      assert length(all_returned_events) == @total_events


      assert all_returned_events |> Enum.map(& &1.data) == all_events
    end

    test "returns all events in descending chunks", %{all_events: all_events} do
      chunk_size = 8
      streams_to_read = [{@stream_id, 0}]

      result_chunks =
        Reader.stream(streams_to_read, :desc, chunk_size)
        |> Enum.to_list()

      # Assertions for chunks: 25 events in chunks of 8 -> 8, 8, 8, 1
      assert length(result_chunks) == 4
      assert length(Enum.at(result_chunks, 0)) == 8
      assert length(Enum.at(result_chunks, 3)) == 1

      all_returned_events = List.flatten(result_chunks)
      assert length(all_returned_events) == @total_events

      # For descending order, the expected result is the reverse
      expected_events = all_events |> Enum.reverse()

      assert all_returned_events |> Enum.map(& &1.data) == expected_events
    end

    test "returns one chunk when chunk size is larger than total events" do
      chunk_size = 100 # Much larger than @total_events (25)
      streams_to_read = [{@stream_id, 0}]

      result_chunks =
        Reader.stream(streams_to_read, :asc, chunk_size)
        |> Enum.to_list()

      # We expect a single chunk containing all events
      assert length(result_chunks) == 1
      assert length(Enum.at(result_chunks, 0)) == @total_events
    end

    test "returns an empty list when no events match" do
      streams_to_read = [{"non-existent-stream", 0}]

      result =
        Reader.stream(streams_to_read, :asc, 1000)
        |> Enum.to_list()

      assert result == []
    end
  end
end
