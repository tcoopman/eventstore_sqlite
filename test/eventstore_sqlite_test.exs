defmodule EventstoreSqliteTest do
  use ExUnit.Case
  use Mneme
  use EventstoreSqlite.DataCase
  use TypedStruct

  alias Ecto.Adapters.SQL

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

  describe "append_to_stream/2 stream ids with SQL metacharacters" do
    test "stream id containing an apostrophe round-trips" do
      stream_id = "o'brien-orders"
      event = %FooTestEvent{text: "hello"}

      assert :ok = EventstoreSqlite.append_to_stream(stream_id, [event])

      assert [
               %EventstoreSqlite.RecordedEvent{stream_id: ^stream_id, data: ^event, stream_version: 0}
             ] = stream_forward(stream_id)
    end

    test "an injection attempt in the stream id is treated as data, not SQL" do
      stream_id = "x'); DROP TABLE events;--"
      event = %FooTestEvent{text: "still here"}

      assert :ok = EventstoreSqlite.append_to_stream(stream_id, [event])

      # The malicious id round-trips as a plain stream id ...
      assert [%EventstoreSqlite.RecordedEvent{data: ^event}] = stream_forward(stream_id)

      # ... and the events table still exists and accepts writes.
      assert :ok = EventstoreSqlite.append_to_stream("normal-stream", [event])
      assert [%EventstoreSqlite.RecordedEvent{data: ^event}] = stream_forward("normal-stream")
    end

    test "multiple appends to an apostrophe stream id keep correct versions" do
      stream_id = "a'b"
      e1 = %FooTestEvent{text: "1"}
      e2 = %FooTestEvent{text: "2"}

      assert :ok = EventstoreSqlite.append_to_stream(stream_id, [e1, e2])
      assert :ok = EventstoreSqlite.append_to_stream(stream_id, [e1])

      assert [
               %EventstoreSqlite.RecordedEvent{data: ^e1, stream_version: 0},
               %EventstoreSqlite.RecordedEvent{data: ^e2, stream_version: 1},
               %EventstoreSqlite.RecordedEvent{data: ^e1, stream_version: 2}
             ] = stream_forward(stream_id)
    end
  end

  describe "append_to_stream/2 metadata" do
    test "an event appended without metadata reads back as an empty map" do
      stream_id = "no-metadata"
      event = %FooTestEvent{text: "hello"}
      :ok = EventstoreSqlite.append_to_stream(stream_id, [event])

      assert [%EventstoreSqlite.RecordedEvent{metadata: %{}}] = stream_forward(stream_id)
    end

    test "no metadata is stored as NULL, not as an encoded empty map" do
      :ok = EventstoreSqlite.append_to_stream("no-metadata", [%FooTestEvent{text: "hello"}])

      assert %{rows: [[nil]]} = SQL.query!(EventstoreSqlite.RepoRead, "SELECT metadata FROM events", [])
    end

    test "metadata round-trips with atom keys intact" do
      stream_id = "scan-1"
      correlation_id = Uniq.UUID.uuid7()
      causation_id = Uniq.UUID.uuid7()

      new_event = %EventstoreSqlite.NewEvent{
        data: %FooTestEvent{text: "scanned"},
        metadata: %{correlation_id: correlation_id, causation_id: causation_id}
      }

      :ok = EventstoreSqlite.append_to_stream(stream_id, [new_event])

      assert [%EventstoreSqlite.RecordedEvent{metadata: metadata}] = stream_forward(stream_id)
      assert metadata == %{correlation_id: correlation_id, causation_id: causation_id}
    end

    test "metadata holding a nested struct survives the round trip" do
      stream_id = "nested-metadata"

      new_event = %EventstoreSqlite.NewEvent{
        data: %FooTestEvent{text: "hello"},
        metadata: %{origin: %Complex{c: "complex"}}
      }

      :ok = EventstoreSqlite.append_to_stream(stream_id, [new_event])

      assert [%EventstoreSqlite.RecordedEvent{metadata: %{origin: %Complex{c: "complex"}}}] =
               stream_forward(stream_id)
    end

    test "an event written while metadata was a JSON map column reads back as an empty map" do
      stream_id = "legacy-metadata"
      event = %FooTestEvent{text: "legacy"}
      event_id = Uniq.UUID.uuid7()
      inserted_at = DateTime.to_iso8601(DateTime.truncate(DateTime.utc_now(), :second))

      SQL.query!(
        EventstoreSqlite.RepoWrite,
        "INSERT INTO events (id, type, data, metadata, inserted_at) VALUES (?, ?, ?, 'null', ?)",
        [event_id, Atom.to_string(FooTestEvent), :erlang.term_to_binary(event), inserted_at]
      )

      SQL.query!(
        EventstoreSqlite.RepoWrite,
        "INSERT INTO streams (stream_id, stream_version, inserted_at) VALUES (?, 1, ?)",
        [stream_id, inserted_at]
      )

      SQL.query!(
        EventstoreSqlite.RepoWrite,
        "INSERT INTO stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version) VALUES (?, ?, 0, ?, 0)",
        [event_id, stream_id, stream_id]
      )

      assert %{rows: [["text", "null"]]} =
               SQL.query!(EventstoreSqlite.RepoRead, "SELECT typeof(metadata), metadata FROM events", [])

      assert [%EventstoreSqlite.RecordedEvent{id: ^event_id, data: ^event, metadata: metadata}] =
               stream_forward(stream_id)

      assert metadata == %{}
    end

    test "bare events and NewEvents can be mixed in one append" do
      stream_id = "mixed"
      bare = %FooTestEvent{text: "bare"}
      wrapped = %EventstoreSqlite.NewEvent{data: %FooTestEvent{text: "wrapped"}, metadata: %{a: 1}}

      :ok = EventstoreSqlite.append_to_stream(stream_id, [bare, wrapped])

      assert [
               %EventstoreSqlite.RecordedEvent{data: ^bare, metadata: %{}, stream_version: 0},
               %EventstoreSqlite.RecordedEvent{
                 data: %FooTestEvent{text: "wrapped"},
                 metadata: %{a: 1},
                 stream_version: 1
               }
             ] = stream_forward(stream_id)
    end

    test "metadata is returned when reading backward too" do
      stream_id = "backward-metadata"

      new_event = %EventstoreSqlite.NewEvent{
        data: %FooTestEvent{text: "hello"},
        metadata: %{causation_id: "abc"}
      }

      :ok = EventstoreSqlite.append_to_stream(stream_id, [new_event])

      assert [%EventstoreSqlite.RecordedEvent{metadata: %{causation_id: "abc"}}] =
               stream_backward(stream_id)
    end

    test "metadata is returned on the $all stream" do
      new_event = %EventstoreSqlite.NewEvent{
        data: %FooTestEvent{text: "hello"},
        metadata: %{causation_id: "abc"}
      }

      :ok = EventstoreSqlite.append_to_stream("some-stream", [new_event])

      assert [%EventstoreSqlite.RecordedEvent{stream_id: "$all", metadata: %{causation_id: "abc"}}] =
               stream_forward("$all")
    end

    test "a row written before metadata existed reads back as an empty map" do
      id = Uniq.UUID.uuid7()

      SQL.query!(
        EventstoreSqlite.RepoWrite,
        "INSERT INTO events (id, type, data, metadata, inserted_at) VALUES (?, ?, ?, NULL, ?)",
        [
          id,
          "Elixir.EventstoreSqliteTest.FooTestEvent",
          :erlang.term_to_binary(%FooTestEvent{text: "legacy"}),
          DateTime.to_iso8601(DateTime.truncate(DateTime.utc_now(), :second))
        ]
      )

      SQL.query!(
        EventstoreSqlite.RepoWrite,
        "INSERT INTO streams (stream_id, stream_version, inserted_at) VALUES (?, 1, ?)",
        ["legacy-stream", DateTime.to_iso8601(DateTime.truncate(DateTime.utc_now(), :second))]
      )

      SQL.query!(
        EventstoreSqlite.RepoWrite,
        "INSERT INTO stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version) VALUES (?, ?, 0, ?, 0)",
        [id, "legacy-stream", "legacy-stream"]
      )

      assert [
               %EventstoreSqlite.RecordedEvent{
                 data: %FooTestEvent{text: "legacy"},
                 metadata: %{}
               }
             ] = stream_forward("legacy-stream")
    end
  end

  describe "append_to_stream/2 caller-supplied event id" do
    test "the supplied id becomes the recorded event's id" do
      stream_id = "own-id"
      id = Uniq.UUID.uuid7()

      new_event = %EventstoreSqlite.NewEvent{id: id, data: %FooTestEvent{text: "hello"}}

      :ok = EventstoreSqlite.append_to_stream(stream_id, [new_event])

      assert [%EventstoreSqlite.RecordedEvent{id: ^id}] = stream_forward(stream_id)
    end

    test "an id is still minted when none is supplied" do
      stream_id = "minted-id"
      :ok = EventstoreSqlite.append_to_stream(stream_id, [%FooTestEvent{text: "hello"}])

      assert [%EventstoreSqlite.RecordedEvent{id: id}] = stream_forward(stream_id)
      assert {:ok, _} = Uniq.UUID.parse(id)
    end

    test "an event can reference a sibling appended in the same batch" do
      stream_id = "flow"
      scan_id = Uniq.UUID.uuid7()

      events = [
        %EventstoreSqlite.NewEvent{
          id: scan_id,
          data: %FooTestEvent{text: "scanned"},
          metadata: %{correlation_id: scan_id, causation_id: nil}
        },
        %EventstoreSqlite.NewEvent{
          data: %FooTestEvent{text: "printed"},
          metadata: %{correlation_id: scan_id, causation_id: scan_id}
        }
      ]

      :ok = EventstoreSqlite.append_to_stream(stream_id, events)

      assert [
               %EventstoreSqlite.RecordedEvent{id: ^scan_id, metadata: %{causation_id: nil}},
               %EventstoreSqlite.RecordedEvent{metadata: %{causation_id: ^scan_id}}
             ] = stream_forward(stream_id)
    end

    test "a malformed id is rejected before anything is written" do
      new_event = %EventstoreSqlite.NewEvent{id: "not-a-uuid", data: %FooTestEvent{text: "hello"}}

      assert_raise ArgumentError, fn ->
        EventstoreSqlite.append_to_stream("bad-id", [new_event])
      end

      assert [] = stream_forward("bad-id")
    end

    test "a duplicate id aborts the whole append" do
      id = Uniq.UUID.uuid7()
      first = %EventstoreSqlite.NewEvent{id: id, data: %FooTestEvent{text: "first"}}
      :ok = EventstoreSqlite.append_to_stream("dup", [first])

      second = %EventstoreSqlite.NewEvent{id: id, data: %FooTestEvent{text: "second"}}

      assert_raise Exqlite.Error, fn ->
        EventstoreSqlite.append_to_stream("dup", [%FooTestEvent{text: "sibling"}, second])
      end

      assert [%EventstoreSqlite.RecordedEvent{data: %FooTestEvent{text: "first"}}] =
               stream_forward("dup")
    end
  end

  describe "event immutability" do
    test "events cannot be deleted" do
      :ok = EventstoreSqlite.append_to_stream("immutable", [%FooTestEvent{text: "x"}])

      error =
        catch_error(SQL.query!(EventstoreSqlite.RepoWrite, "DELETE FROM events", []))

      assert Exception.message(error) =~ "cannot delete events"
    end

    test "events cannot be updated" do
      :ok = EventstoreSqlite.append_to_stream("immutable", [%FooTestEvent{text: "x"}])

      error =
        catch_error(SQL.query!(EventstoreSqlite.RepoWrite, "UPDATE events SET type = 'tampered'", []))

      assert Exception.message(error) =~ "cannot update events"
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
    stream_id |> EventstoreSqlite.stream_forward(opts) |> Enum.to_list()
  end

  defp stream_backward(stream_id, opts \\ []) do
    stream_id |> EventstoreSqlite.stream_backward(opts) |> Enum.to_list()
  end
end
