defmodule EventstoreSqlite.SubscribeTest do
  use ExUnit.Case

  use Mneme
  use EventstoreSqlite.DataCase
  use TypedStruct

  doctest EventstoreSqlite

  typedstruct module: FooTestEvent do
    field(:text, :string)
  end

  typedstruct module: Complex do
    field(:c, :string)
  end

  typedstruct module: ComplexEvent do
    field(:complex, Complex.t())
  end

  describe "subscribe to $all stream" do
    @tag :skip
    test "no events are added to the stream" do
      assert :ok = EventstoreSqlite.subscribe_to_stream("$all")
      assert :ok = EventstoreSqlite.append_to_stream("test-stream-1", [])

      refute_receive(_)
    end

    @tag :skip
    test "a single event is added" do
      assert :ok = EventstoreSqlite.subscribe_to_stream("$all")
      event = %FooTestEvent{text: "some text"}
      assert :ok = EventstoreSqlite.append_to_stream("test-stream-1", [event])

      auto_assert_receive(
        {:events,
         [
           %EventstoreSqlite.RecordedEvent{
             data: %FooTestEvent{text: "some text"},
             stream_id: "$all",
             stream_version: 0,
             type: "Elixir.EventstoreSqlite.SubscribeTest.FooTestEvent"
           }
         ]}
      )
    end

    @tag :skip
    test "multiple events are added" do
      assert :ok = EventstoreSqlite.subscribe_to_stream("$all")
      event = %FooTestEvent{text: "some text"}
      assert :ok = EventstoreSqlite.append_to_stream("test-stream-1", [event, event, event])

      auto_assert_receive(
        {:events,
         [
           %EventstoreSqlite.RecordedEvent{
             data: %FooTestEvent{text: "some text"},
             stream_id: "$all",
             stream_version: 0,
             type: "Elixir.EventstoreSqlite.SubscribeTest.FooTestEvent"
           },
           %EventstoreSqlite.RecordedEvent{
             data: %FooTestEvent{text: "some text"},
             stream_id: "$all",
             stream_version: 1,
             type: "Elixir.EventstoreSqlite.SubscribeTest.FooTestEvent"
           },
           %EventstoreSqlite.RecordedEvent{
             data: %FooTestEvent{text: "some text"},
             stream_id: "$all",
             stream_version: 2,
             type: "Elixir.EventstoreSqlite.SubscribeTest.FooTestEvent"
           }
         ]}
      )
    end

    @tag :skip
    test "multiple steps" do
      assert :ok = EventstoreSqlite.subscribe_to_stream("$all")
      event = %FooTestEvent{text: "some text"}
      assert :ok = EventstoreSqlite.append_to_stream("test-stream-1", [event])

      auto_assert_receive(
        {:events,
         [
           %EventstoreSqlite.RecordedEvent{
             data: %FooTestEvent{text: "some text"},
             stream_id: "$all",
             stream_version: 0,
             type: "Elixir.EventstoreSqlite.SubscribeTest.FooTestEvent"
           }
         ]}
      )

      assert :ok = EventstoreSqlite.append_to_stream("test-stream-1", [event])
      auto_assert_receive()
    end
  end
end
