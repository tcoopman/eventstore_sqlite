defmodule EventstoreSqlite.ManyEventsTest do
  use EventstoreSqlite.DataCase
  use Mneme
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

  setup do
    insert_many("A", 3_000)
    insert_many("B", 3_000)
    insert_many("C", 3_000)
    insert_many("D", 3_000)
    insert_many("E", 3_000)
    insert_many("A", 3_000)
    insert_many("B", 3_000)
    insert_many("C", 3_000)
    insert_many("D", 3_000)
    insert_many("E", 3_000)
    :ok
  end

  describe "read_stream_forward" do
    test "sanity with limit" do
      all = EventstoreSqlite.read_stream_forward("$all", count: 20_000)
      auto_assert(20_000 <- Enum.count(all))
    end

    test "first 2" do
      auto_assert(
        [
          %EventstoreSqlite.RecordedEvent{
            data: %FooTestEvent{text: "event: 0"},
            stream_id: "$all",
            stream_version: 0,
            type: "Elixir.EventstoreSqlite.ManyEventsTest.FooTestEvent"
          },
          %EventstoreSqlite.RecordedEvent{
            data: %FooTestEvent{text: "event: 1"},
            stream_id: "$all",
            stream_version: 1,
            type: "Elixir.EventstoreSqlite.ManyEventsTest.FooTestEvent"
          }
        ] <- EventstoreSqlite.read_stream_forward({"$all", 0}, count: 2)
      )
    end

    test "start_version still works with big numbers as well" do
      auto_assert(
        [
          %EventstoreSqlite.RecordedEvent{
            data: %FooTestEvent{text: "event: 2999"},
            stream_id: "$all",
            stream_version: 29_999,
            type: "Elixir.EventstoreSqlite.ManyEventsTest.FooTestEvent"
          }
        ] <- EventstoreSqlite.read_stream_forward({"$all", 3_000 * 10 - 1}, count: 2)
      )
    end
  end

  defp insert_many(stream, number) do
    events = for i <- 0..(number - 1), do: %FooTestEvent{text: "event: #{i}"}

    assert :ok = EventstoreSqlite.append_to_stream(stream, events)
  end
end
