defmodule EventstoreSqliteTest do
  use ExUnit.Case

  use Mneme
  use EventstoreSqlite.DataCase
  use TypedStruct

  doctest EventstoreSqlite

  alias EventstoreSqliteTest.FooTestEvent
  alias EventstoreSqlite.Event

  typedstruct module: FooTestEvent do
    field(:text, :string)
  end

  defmodule Complex do
    @derive Jason.Encoder
    typedstruct do
      field(:c, :string)
    end
  end

  typedstruct module: ComplexEvent do
    field(:complex, Complex.t())
  end

  describe "append_to_stream/2" do
    test "no events" do
      assert :ok = EventstoreSqlite.append_to_stream("test-stream-1", [])
    end

    test "1 event" do
      event = Event.new(%FooTestEvent{text: "some text"})
      assert :ok = EventstoreSqlite.append_to_stream("test-stream-1", [event])
    end

    test "events must be unique" do
      stream_id = "test-stream-1"
      event = Event.new(%FooTestEvent{text: "some text"})

      auto_assert_raise(
        Exqlite.Error,
        EventstoreSqlite.append_to_stream(stream_id, [event, event])
      )
    end

    test "handles nested structures" do
      event = Event.new(%ComplexEvent{complex: %Complex{c: "complex"}})
      assert :ok = EventstoreSqlite.append_to_stream("test-stream-1", [event])
    end
  end

  describe "read_stream_forward" do
    test "stream does not exist" do
      auto_assert(
        [] <- EventstoreSqlite.read_stream_forward("does-not-exist", start_version: 0, count: 1)
      )
    end

    test "1 event" do
      stream_id = "test-stream-1"
      event = Event.new(%FooTestEvent{text: "some text"})
      :ok = EventstoreSqlite.append_to_stream(stream_id, [event])

      auto_assert(
        [
          %EventstoreSqlite.RecordedEvent{
            data: %FooTestEvent{text: "some text"}
          }
        ] <- EventstoreSqlite.read_stream_forward(stream_id, start_version: 0, count: 1)
      )
    end

    test "respect count" do
      stream_id = "test-stream-1"
      event1 = Event.new(%FooTestEvent{text: "some text"})
      event2 = Event.new(%FooTestEvent{text: "some text"})
      event3 = Event.new(%FooTestEvent{text: "some text"})
      :ok = EventstoreSqlite.append_to_stream(stream_id, [event1, event2, event3])

      auto_assert(
        [
          %EventstoreSqlite.RecordedEvent{
            data: %FooTestEvent{text: "some text"}
          }
        ] <- EventstoreSqlite.read_stream_forward(stream_id, start_version: 0, count: 1)
      )
    end

    test "respect start version" do
      stream_id = "test-stream-1"
      event_1 = Event.new(%FooTestEvent{text: "1"})
      event_2 = Event.new(%FooTestEvent{text: "2"})
      event_3 = Event.new(%FooTestEvent{text: "3"})
      :ok = EventstoreSqlite.append_to_stream(stream_id, [event_1, event_2, event_3])

      auto_assert(
        [
          %EventstoreSqlite.RecordedEvent{
            data: %FooTestEvent{text: "2"}
          },
          %EventstoreSqlite.RecordedEvent{
            data: %FooTestEvent{text: "3"}
          }
        ] <- EventstoreSqlite.read_stream_forward(stream_id, start_version: 1)
      )

      auto_assert([] <- EventstoreSqlite.read_stream_forward("empty-stream"))
    end

    test "handles nested structures" do
      event = Event.new(%ComplexEvent{complex: %Complex{c: "complex"}})
      assert :ok = EventstoreSqlite.append_to_stream("test-stream-1", [event])

      auto_assert(
        [
          %EventstoreSqlite.RecordedEvent{
            data: %ComplexEvent{complex: %{"c" => "complex"}},
            id: "018bf0f4-7e78-7bf0-baaf-4716ae307af6"
          }
        ] <- EventstoreSqlite.read_stream_forward("test-stream-1")
      )
    end
  end
end
