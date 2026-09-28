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

  describe "default :count" do
    test "stream_forward and stream_backward read the whole stream" do
      assert "$all" |> EventstoreSqlite.stream_forward() |> Enum.count() == 30_000
      assert "$all" |> EventstoreSqlite.stream_backward() |> Enum.count() == 30_000
    end

    test "read_stream_forward and read_stream_backward still stop at 10_000" do
      assert "$all" |> EventstoreSqlite.read_stream_forward() |> Enum.count() == 10_000
      assert "$all" |> EventstoreSqlite.read_stream_backward() |> Enum.count() == 10_000
    end

    test "count: nil lifts the read_stream limit" do
      assert "$all" |> EventstoreSqlite.read_stream_forward(count: nil) |> Enum.count() == 30_000
    end
  end

  describe "subscription catch-up" do
    test "a subscriber more than one batch behind receives the whole history" do
      :ok = EventstoreSqlite.subscribe_to_stream(self(), "$all")

      assert_receive {:events, first}, 5_000
      assert_receive {:events, second}, 5_000
      assert_receive {:events, third}, 5_000
      refute_receive {:events, _}, 100

      assert Enum.map([first, second, third], &length/1) == [10_000, 10_000, 10_000]
      assert Enum.map(first ++ second ++ third, & &1.stream_version) == Enum.to_list(0..29_999)
    end

    test "catch-up honours :batch_size" do
      :ok = EventstoreSqlite.subscribe_to_stream(self(), "A", 0, nil, batch_size: 2_500)

      batches =
        for _ <- 1..3 do
          assert_receive {:events, events}, 5_000
          events
        end

      refute_receive {:events, _}, 100

      assert Enum.map(batches, &length/1) == [2_500, 2_500, 1_000]
      assert Enum.map(List.flatten(batches), & &1.stream_version) == Enum.to_list(0..5_999)
    end
  end

  defp insert_many(stream, number) do
    events = for i <- 0..(number - 1), do: %FooTestEvent{text: "event: #{i}"}

    assert :ok = EventstoreSqlite.append_to_stream(stream, events)
  end
end
