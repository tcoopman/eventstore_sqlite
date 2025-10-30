defmodule EventstoreSqliteTest do
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

  describe "append_to_stream/2" do
    test "no events" do
      assert :ok = EventstoreSqlite.append_to_stream("test-stream-1", [])
    end

    test "1 event" do
      event = %FooTestEvent{text: "some text"}
      assert :ok = EventstoreSqlite.append_to_stream("test-stream-1", [event])
    end

    test "multitple events after each other" do
      event = %FooTestEvent{text: "some text"}
      assert :ok = EventstoreSqlite.append_to_stream("test-stream-1", [event])
      assert :ok = EventstoreSqlite.append_to_stream("test-stream-1", [event, event])
      assert :ok = EventstoreSqlite.append_to_stream("test-stream-1", [event, event, event])
    end

    test "multitple events at the start" do
      event = %FooTestEvent{text: "some text"}
      assert :ok = EventstoreSqlite.append_to_stream("test-stream-1", [event, event])
    end

    test "handles nested structures" do
      event = %ComplexEvent{complex: %Complex{c: "complex"}}
      assert :ok = EventstoreSqlite.append_to_stream("test-stream-1", [event])
    end

    test "only when the stream does not exist yet" do
      event = %ComplexEvent{complex: %Complex{c: "complex"}}
      assert :ok = EventstoreSqlite.append_to_stream("test-stream-1", [event], :no_stream)

      assert {:error, :wrong_expected_version} =
               EventstoreSqlite.append_to_stream("test-stream-1", [event], :no_stream)
    end

    test "only when the stream already exists" do
      event = %ComplexEvent{complex: %Complex{c: "complex"}}

      assert {:error, :wrong_expected_version} =
               EventstoreSqlite.append_to_stream("test-stream-1", [event], :stream_exists)
    end

    test "only when the correct version already exists" do
      event = %ComplexEvent{complex: %Complex{c: "complex"}}

      assert :ok =
               EventstoreSqlite.append_to_stream("test-stream-1", [event])

      assert {:error, :wrong_expected_version} =
               EventstoreSqlite.append_to_stream("test-stream-1", [event], {:version, 0})

      assert :ok =
               EventstoreSqlite.append_to_stream("test-stream-1", [event], {:version, 1})

      assert :ok =
               EventstoreSqlite.append_to_stream("test-stream-1", [event], {:version, 2})
    end

    test "stream version 0 also works, only if it doesn't exist yet" do
      event = %ComplexEvent{complex: %Complex{c: "complex"}}

      assert :ok =
               EventstoreSqlite.append_to_stream("test-stream-1", [event], {:version, 0})
    end
  end

  describe "read_stream_forward" do
    test "stream does not exist" do
      auto_assert([] <- stream_forward("does-not-exist", count: 1))
    end

    test "1 event" do
      stream_id = "test-stream-1"
      event = %FooTestEvent{text: "some text"}
      :ok = EventstoreSqlite.append_to_stream(stream_id, [event])

      auto_assert(
        [
          %EventstoreSqlite.RecordedEvent{
            created_at: date,
            data: %FooTestEvent{text: "some text"},
            stream_id: "test-stream-1",
            type: "Elixir.EventstoreSqliteTest.FooTestEvent",
            stream_version: 0
          }
        ]
        when is_struct(date, DateTime) <-
          stream_forward({stream_id, 0}, count: 1)
      )
    end

    test "respect count" do
      stream_id = "test-stream-1"
      event1 = %FooTestEvent{text: "some text"}
      event2 = %FooTestEvent{text: "some text"}
      event3 = %FooTestEvent{text: "some text"}
      :ok = EventstoreSqlite.append_to_stream(stream_id, [event1, event2, event3])

      auto_assert(
        [
          %EventstoreSqlite.RecordedEvent{
            data: %FooTestEvent{text: "some text"}
          }
        ] <- stream_forward(stream_id, count: 1)
      )
    end

    test "respect start version" do
      stream_id = "test-stream-1"
      event_1 = %FooTestEvent{text: "1"}
      event_2 = %FooTestEvent{text: "2"}
      event_3 = %FooTestEvent{text: "3"}
      :ok = EventstoreSqlite.append_to_stream(stream_id, [event_1, event_2, event_3])

      auto_assert(
        [
          %EventstoreSqlite.RecordedEvent{
            data: %FooTestEvent{text: "2"}
          },
          %EventstoreSqlite.RecordedEvent{
            data: %FooTestEvent{text: "3"}
          }
        ] <- stream_forward({stream_id, 1})
      )

      auto_assert([] <- stream_forward("empty-stream"))
    end

    test "handles nested structures" do
      event = %ComplexEvent{complex: %Complex{c: "complex"}}
      assert :ok = EventstoreSqlite.append_to_stream("test-stream-1", [event])

      auto_assert(
        [
          %EventstoreSqlite.RecordedEvent{
            data: %ComplexEvent{complex: %Complex{c: "complex"}}
          }
        ] <- stream_forward("test-stream-1")
      )
    end

    test "handles multiple streams" do
      stream_id_1 = "test-stream-1"
      stream_id_2 = "test-stream-2"
      event_1 = %FooTestEvent{text: "1"}
      event_2 = %FooTestEvent{text: "2"}
      event_3 = %FooTestEvent{text: "3"}
      :ok = EventstoreSqlite.append_to_stream(stream_id_1, [event_1, event_2])
      :ok = EventstoreSqlite.append_to_stream(stream_id_2, [event_3])

      auto_assert(
        [
          %EventstoreSqlite.RecordedEvent{
            data: ^event_1,
            stream_id: ^stream_id_1
          },
          %EventstoreSqlite.RecordedEvent{
            data: ^event_2,
            stream_id: ^stream_id_1
          },
          %EventstoreSqlite.RecordedEvent{
            data: ^event_3,
            stream_id: ^stream_id_2
          }
        ] <- stream_forward([stream_id_1, stream_id_2])
      )
    end

    test "handles multiple streams in the correct order" do
      stream_id_1 = "test-stream-1"
      stream_id_2 = "test-stream-2"
      event_1 = %FooTestEvent{text: "1"}
      event_2 = %FooTestEvent{text: "2"}
      event_3 = %FooTestEvent{text: "3"}
      event_4 = %FooTestEvent{text: "4"}
      :ok = EventstoreSqlite.append_to_stream(stream_id_1, [event_1, event_2])
      :ok = EventstoreSqlite.append_to_stream(stream_id_2, [event_3])
      :ok = EventstoreSqlite.append_to_stream(stream_id_1, [event_4])

      auto_assert(
        [
          %EventstoreSqlite.RecordedEvent{
            data: ^event_1,
            stream_id: ^stream_id_1
          },
          %EventstoreSqlite.RecordedEvent{
            data: ^event_2,
            stream_id: ^stream_id_1
          },
          %EventstoreSqlite.RecordedEvent{
            data: ^event_3,
            stream_id: ^stream_id_2
          },
          %EventstoreSqlite.RecordedEvent{
            data: ^event_4,
            stream_id: ^stream_id_1
          }
        ] <- stream_forward([stream_id_1, stream_id_2])
      )
    end

    test "combined with all stream - insert order is kept" do
      stream_id_1 = "test-stream-1"
      stream_id_2 = "test-stream-2"
      event_1 = %FooTestEvent{text: "1"}
      event_2 = %FooTestEvent{text: "2"}
      event_3 = %FooTestEvent{text: "3"}
      event_4 = %FooTestEvent{text: "4"}
      :ok = EventstoreSqlite.append_to_stream(stream_id_1, [event_1, event_2])
      :ok = EventstoreSqlite.append_to_stream(stream_id_2, [event_3])
      :ok = EventstoreSqlite.append_to_stream(stream_id_1, [event_4])

      auto_assert(
        [
          %EventstoreSqlite.RecordedEvent{
            data: ^event_1,
            stream_id: ^stream_id_1
          },
          %EventstoreSqlite.RecordedEvent{
            data: ^event_2,
            stream_id: ^stream_id_1
          },
          %EventstoreSqlite.RecordedEvent{
            data: ^event_1,
            stream_id: "$all",
            stream_version: 0
          },
          %EventstoreSqlite.RecordedEvent{
            data: ^event_2,
            stream_id: "$all",
            stream_version: 1
          },
          %EventstoreSqlite.RecordedEvent{
            data: ^event_3,
            stream_id: "$all",
            stream_version: 2
          },
          %EventstoreSqlite.RecordedEvent{
            data: ^event_4,
            stream_id: ^stream_id_1,
            stream_version: 2
          },
          %EventstoreSqlite.RecordedEvent{
            data: ^event_4,
            stream_id: "$all",
            stream_version: 3
          }
        ] <- stream_forward([stream_id_1, "$all"])
      )
    end

    test "multiple streams with start_version" do
      stream_id_1 = "test-stream-1"
      stream_id_2 = "test-stream-2"
      event_1 = %FooTestEvent{text: "1"}
      event_2 = %FooTestEvent{text: "2"}
      event_3 = %FooTestEvent{text: "3"}
      event_4 = %FooTestEvent{text: "4"}
      event_5 = %FooTestEvent{text: "5"}
      event_6 = %FooTestEvent{text: "6"}
      event_7 = %FooTestEvent{text: "7"}
      :ok = EventstoreSqlite.append_to_stream(stream_id_1, [event_1, event_2])
      :ok = EventstoreSqlite.append_to_stream(stream_id_2, [event_3])
      :ok = EventstoreSqlite.append_to_stream(stream_id_1, [event_4])
      :ok = EventstoreSqlite.append_to_stream(stream_id_2, [event_5])
      :ok = EventstoreSqlite.append_to_stream(stream_id_2, [event_6])
      :ok = EventstoreSqlite.append_to_stream(stream_id_1, [event_7])

      auto_assert(
        [
          %EventstoreSqlite.RecordedEvent{
            data: ^event_2,
            stream_id: ^stream_id_1,
            stream_version: 1
          },
          %EventstoreSqlite.RecordedEvent{
            data: ^event_4,
            stream_id: ^stream_id_1,
            stream_version: 2
          },
          %EventstoreSqlite.RecordedEvent{
            data: ^event_6,
            stream_id: ^stream_id_2,
            stream_version: 2
          },
          %EventstoreSqlite.RecordedEvent{
            data: ^event_7,
            stream_id: ^stream_id_1,
            stream_version: 3
          }
        ] <- stream_forward([{stream_id_1, 1}, {stream_id_2, 2}])
      )
    end

    test "$all stream" do
      event_1 = %FooTestEvent{text: "1"}
      event_2 = %FooTestEvent{text: "2"}
      event_3 = %FooTestEvent{text: "3"}
      :ok = EventstoreSqlite.append_to_stream("stream-1", [event_1, event_2, event_3])
      :ok = EventstoreSqlite.append_to_stream("stream-2", [event_2, event_3])

      auto_assert(
        [
          %EventstoreSqlite.RecordedEvent{
            data: %FooTestEvent{text: "1"},
            type: "Elixir.EventstoreSqliteTest.FooTestEvent"
          },
          %EventstoreSqlite.RecordedEvent{
            data: %FooTestEvent{text: "2"},
            type: "Elixir.EventstoreSqliteTest.FooTestEvent"
          },
          %EventstoreSqlite.RecordedEvent{
            data: %FooTestEvent{text: "3"},
            type: "Elixir.EventstoreSqliteTest.FooTestEvent"
          },
          %EventstoreSqlite.RecordedEvent{
            data: %FooTestEvent{text: "2"},
            type: "Elixir.EventstoreSqliteTest.FooTestEvent"
          },
          %EventstoreSqlite.RecordedEvent{
            data: %FooTestEvent{text: "3"},
            type: "Elixir.EventstoreSqliteTest.FooTestEvent"
          }
        ] <- stream_forward("$all")
      )
    end
  end

  describe "read_stream_backward" do
    test "stream does not exist" do
      auto_assert([] <- stream_backward("does-not-exist", count: 1))
    end

    test "1 event" do
      stream_id = "test-stream-1"
      event = %FooTestEvent{text: "some text"}
      :ok = EventstoreSqlite.append_to_stream(stream_id, [event])

      auto_assert(
        [
          %EventstoreSqlite.RecordedEvent{
            created_at: date,
            data: %FooTestEvent{text: "some text"},
            stream_id: "test-stream-1",
            type: "Elixir.EventstoreSqliteTest.FooTestEvent",
            stream_version: 0
          }
        ]
        when is_struct(date, DateTime) <-
          stream_backward(stream_id, count: 1)
      )
    end

    test "multiple events" do
      stream_id = "test-stream-1"
      event1 = %FooTestEvent{text: "1"}
      event2 = %FooTestEvent{text: "2"}
      event3 = %FooTestEvent{text: "3"}
      :ok = EventstoreSqlite.append_to_stream(stream_id, [event1, event2, event3])

      auto_assert(
        [
          %EventstoreSqlite.RecordedEvent{data: %FooTestEvent{text: "3"}},
          %EventstoreSqlite.RecordedEvent{data: %FooTestEvent{text: "2"}},
          %EventstoreSqlite.RecordedEvent{data: %FooTestEvent{text: "1"}}
        ] <- stream_backward(stream_id)
      )
    end

    test "respect count" do
      stream_id = "test-stream-1"
      event1 = %FooTestEvent{text: "1"}
      event2 = %FooTestEvent{text: "2"}
      event3 = %FooTestEvent{text: "3"}
      :ok = EventstoreSqlite.append_to_stream(stream_id, [event1, event2, event3])

      auto_assert(
        [
          %EventstoreSqlite.RecordedEvent{
            data: %FooTestEvent{text: "3"}
          }
        ] <- stream_backward(stream_id, count: 1)
      )
    end

    test "handles nested structures" do
      event = %ComplexEvent{complex: %Complex{c: "complex"}}
      assert :ok = EventstoreSqlite.append_to_stream("test-stream-1", [event])

      auto_assert(
        [
          %EventstoreSqlite.RecordedEvent{
            data: %ComplexEvent{complex: %Complex{c: "complex"}}
          }
        ] <- stream_backward("test-stream-1")
      )
    end

    test "handles multiple streams" do
      stream_id_1 = "test-stream-1"
      stream_id_2 = "test-stream-2"
      event_1 = %FooTestEvent{text: "1"}
      event_2 = %FooTestEvent{text: "2"}
      event_3 = %FooTestEvent{text: "3"}
      :ok = EventstoreSqlite.append_to_stream(stream_id_1, [event_1, event_2])
      :ok = EventstoreSqlite.append_to_stream(stream_id_2, [event_3])

      auto_assert(
        [
          %EventstoreSqlite.RecordedEvent{data: ^event_3, stream_id: ^stream_id_2},
          %EventstoreSqlite.RecordedEvent{data: ^event_2, stream_id: ^stream_id_1},
          %EventstoreSqlite.RecordedEvent{data: ^event_1, stream_id: ^stream_id_1}
        ] <- stream_backward([stream_id_1, stream_id_2])
      )
    end

    test "handles multiple streams in the correct order" do
      stream_id_1 = "test-stream-1"
      stream_id_2 = "test-stream-2"
      event_1 = %FooTestEvent{text: "1"}
      event_2 = %FooTestEvent{text: "2"}
      event_3 = %FooTestEvent{text: "3"}
      event_4 = %FooTestEvent{text: "4"}
      :ok = EventstoreSqlite.append_to_stream(stream_id_1, [event_1, event_2])
      :ok = EventstoreSqlite.append_to_stream(stream_id_2, [event_3])
      :ok = EventstoreSqlite.append_to_stream(stream_id_1, [event_4])

      auto_assert(
        [
          %EventstoreSqlite.RecordedEvent{data: ^event_4, stream_id: ^stream_id_1},
          %EventstoreSqlite.RecordedEvent{data: ^event_3, stream_id: ^stream_id_2},
          %EventstoreSqlite.RecordedEvent{data: ^event_2, stream_id: ^stream_id_1},
          %EventstoreSqlite.RecordedEvent{data: ^event_1, stream_id: ^stream_id_1}
        ] <- stream_backward([stream_id_1, stream_id_2])
      )
    end

    test "combined with all stream - insert order is kept" do
      stream_id_1 = "test-stream-1"
      stream_id_2 = "test-stream-2"
      event_1 = %FooTestEvent{text: "1"}
      event_2 = %FooTestEvent{text: "2"}
      event_3 = %FooTestEvent{text: "3"}
      event_4 = %FooTestEvent{text: "4"}
      :ok = EventstoreSqlite.append_to_stream(stream_id_1, [event_1, event_2])
      :ok = EventstoreSqlite.append_to_stream(stream_id_2, [event_3])
      :ok = EventstoreSqlite.append_to_stream(stream_id_1, [event_4])

      auto_assert(
        [
          %EventstoreSqlite.RecordedEvent{data: ^event_4, stream_id: "$all", stream_version: 3},
          %EventstoreSqlite.RecordedEvent{
            data: ^event_4,
            stream_id: ^stream_id_1,
            stream_version: 2
          },
          %EventstoreSqlite.RecordedEvent{data: ^event_3, stream_id: "$all", stream_version: 2},
          %EventstoreSqlite.RecordedEvent{data: ^event_2, stream_id: "$all", stream_version: 1},
          %EventstoreSqlite.RecordedEvent{data: ^event_1, stream_id: "$all", stream_version: 0},
          %EventstoreSqlite.RecordedEvent{
            data: ^event_2,
            stream_id: ^stream_id_1,
            stream_version: 1
          },
          %EventstoreSqlite.RecordedEvent{
            data: ^event_1,
            stream_id: ^stream_id_1,
            stream_version: 0
          }
        ] <- stream_backward([stream_id_1, "$all"])
      )
    end

    test "$all stream" do
      event_1 = %FooTestEvent{text: "1"}
      event_2 = %FooTestEvent{text: "2"}
      event_3 = %FooTestEvent{text: "3"}
      :ok = EventstoreSqlite.append_to_stream("stream-1", [event_1, event_2, event_3])
      :ok = EventstoreSqlite.append_to_stream("stream-2", [event_2, event_3])

      auto_assert(
        [
          %EventstoreSqlite.RecordedEvent{
            data: %FooTestEvent{text: "3"},
            type: "Elixir.EventstoreSqliteTest.FooTestEvent"
          },
          %EventstoreSqlite.RecordedEvent{
            data: %FooTestEvent{text: "2"},
            type: "Elixir.EventstoreSqliteTest.FooTestEvent"
          },
          %EventstoreSqlite.RecordedEvent{
            data: %FooTestEvent{text: "3"},
            type: "Elixir.EventstoreSqliteTest.FooTestEvent"
          },
          %EventstoreSqlite.RecordedEvent{
            data: %FooTestEvent{text: "2"},
            type: "Elixir.EventstoreSqliteTest.FooTestEvent"
          },
          %EventstoreSqlite.RecordedEvent{
            data: %FooTestEvent{text: "1"},
            type: "Elixir.EventstoreSqliteTest.FooTestEvent"
          }
        ] <- stream_backward("$all")
      )
    end
  end

  describe "list_streams/0" do
    test "no streams" do
      auto_assert([] <- EventstoreSqlite.list_streams())
    end

    test "multiple streams" do
      event_1 = %FooTestEvent{text: "1"}
      event_2 = %FooTestEvent{text: "2"}
      :ok = EventstoreSqlite.append_to_stream("stream-1", [event_1])
      :ok = EventstoreSqlite.append_to_stream("stream-2", [event_2])

      auto_assert(["$all", "stream-1", "stream-2"] <- EventstoreSqlite.list_streams())
    end
  end

  defp stream_forward(stream_id, opts \\ []) do
    EventstoreSqlite.stream_forward(stream_id, opts) |> Enum.to_list()
  end

  defp stream_backward(stream_id, opts \\ []) do
    EventstoreSqlite.stream_backward(stream_id, opts) |> Enum.to_list()
  end
end
