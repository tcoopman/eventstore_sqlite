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

  defmodule Subscriber do
    use GenServer

    def subscribe(stream, start_version \\ 0) do
      GenServer.start_link(__MODULE__, {stream, start_version})
    end

    def events(pid, timeout \\ 10) do
      GenServer.call(pid, {:get_events, timeout})
    end

    @impl true
    def init({stream, start_version}) do
      :ok = EventstoreSqlite.subscribe_to_stream(self(), stream, start_version)
      {:ok, []}
    end

    @impl true
    def handle_call({:get_events, timeout}, caller, state) do
      Process.send_after(self(), {:reply, caller}, timeout)
      {:noreply, state}
    end

    @impl true
    def handle_info({:events, events}, state) do
      {:noreply, state ++ events}
    end

    @impl true
    def handle_info({:reply, from}, state) do
      GenServer.reply(from, state)
      {:noreply, state}
    end
  end

  describe "subscribe_to_stream/4 $all stream" do
    test "no events are added to the stream" do
      {:ok, pid} = Subscriber.subscribe("$all")
      assert :ok = EventstoreSqlite.append_to_stream("test-stream-1", [])

      auto_assert([] <- Subscriber.events(pid))
    end

    test "a single event is added" do
      {:ok, pid} = Subscriber.subscribe("$all")
      event = %FooTestEvent{text: "some text"}
      assert :ok = EventstoreSqlite.append_to_stream("test-stream-1", [event])

      auto_assert(
        [
          %EventstoreSqlite.RecordedEvent{
            stream_id: "$all",
            stream_version: 0
          }
        ] <- Subscriber.events(pid)
      )
    end

    test "multiple events are added" do
      {:ok, pid} = Subscriber.subscribe("$all")
      event = %FooTestEvent{text: "some text"}
      assert :ok = EventstoreSqlite.append_to_stream("test-stream-1", [event, event, event])

      auto_assert(
        [
          %EventstoreSqlite.RecordedEvent{
            stream_id: "$all",
            stream_version: 0
          },
          %EventstoreSqlite.RecordedEvent{
            stream_id: "$all",
            stream_version: 1
          },
          %EventstoreSqlite.RecordedEvent{
            stream_id: "$all",
            stream_version: 2
          }
        ] <- Subscriber.events(pid)
      )
    end

    test "multiple steps only receives the current ones" do
      {:ok, pid} = Subscriber.subscribe("$all")
      event = %FooTestEvent{text: "some text"}
      assert :ok = EventstoreSqlite.append_to_stream("test-stream-1", [event])

      auto_assert(
        [
          %EventstoreSqlite.RecordedEvent{
            stream_id: "$all",
            stream_version: 0
          }
        ] <- Subscriber.events(pid)
      )

      assert :ok = EventstoreSqlite.append_to_stream("test-stream-1", [event])

      auto_assert(
        [
          %EventstoreSqlite.RecordedEvent{
            stream_id: "$all",
            stream_version: 0
          },
          %EventstoreSqlite.RecordedEvent{
            stream_id: "$all",
            stream_version: 1
          }
        ] <- Subscriber.events(pid)
      )
    end

    test "only receives minimum version on subscription" do
      event = %FooTestEvent{text: "some text"}
      assert :ok = EventstoreSqlite.append_to_stream("test-stream-1", [event])
      assert :ok = EventstoreSqlite.append_to_stream("test-stream-1", [event])
      assert :ok = EventstoreSqlite.append_to_stream("test-stream-1", [event])

      {:ok, pid} = Subscriber.subscribe("$all", 2)
      assert :ok = EventstoreSqlite.subscribe_to_stream(self(), "$all", 2)
      event = %FooTestEvent{text: "some text"}

      auto_assert(
        [
          %EventstoreSqlite.RecordedEvent{
            stream_id: "$all",
            stream_version: 2
          }
        ] <- Subscriber.events(pid)
      )
    end

    test "only receives minimum version on subscription even if that version was not in the stream yet" do
      event = %FooTestEvent{text: "some text"}
      {:ok, pid} = Subscriber.subscribe("$all", 2)

      assert :ok = EventstoreSqlite.append_to_stream("test-stream-1", [event])
      assert :ok = EventstoreSqlite.append_to_stream("test-stream-1", [event])
      assert :ok = EventstoreSqlite.append_to_stream("test-stream-1", [event])

      auto_assert(
        [
          %EventstoreSqlite.RecordedEvent{
            stream_id: "$all",
            stream_version: 2
          }
        ] <- Subscriber.events(pid)
      )
    end
  end

  describe "subscribe_to_stream/4 complex test" do
    test "2 streams subscriptions" do
      event = %FooTestEvent{text: "some text"}

      {:ok, all} = Subscriber.subscribe("$all", 2)
      {:ok, test_stream_1} = Subscriber.subscribe("test-stream-1")
      assert :ok = EventstoreSqlite.append_to_stream("test-stream-1", [event, event, event])
      assert :ok = EventstoreSqlite.append_to_stream("test-stream-1", [event, event])

      auto_assert(
        [
          %EventstoreSqlite.RecordedEvent{stream_id: "test-stream-1", stream_version: 0},
          %EventstoreSqlite.RecordedEvent{stream_id: "test-stream-1", stream_version: 1},
          %EventstoreSqlite.RecordedEvent{stream_id: "test-stream-1", stream_version: 2},
          %EventstoreSqlite.RecordedEvent{stream_id: "test-stream-1", stream_version: 3},
          %EventstoreSqlite.RecordedEvent{stream_id: "test-stream-1", stream_version: 4}
        ] <- Subscriber.events(test_stream_1)
      )

      auto_assert(
        [
          %EventstoreSqlite.RecordedEvent{stream_id: "$all", stream_version: 2},
          %EventstoreSqlite.RecordedEvent{stream_id: "$all", stream_version: 3},
          %EventstoreSqlite.RecordedEvent{stream_id: "$all", stream_version: 4}
        ] <- Subscriber.events(all)
      )
    end

    test "2 different versions subscribed" do
      event = %FooTestEvent{text: "text"}

      {:ok, all_0} = Subscriber.subscribe("$all", 0)
      {:ok, all_5} = Subscriber.subscribe("$all", 5)
      assert :ok = EventstoreSqlite.append_to_stream("test-stream-1", [event, event, event])
      assert :ok = EventstoreSqlite.append_to_stream("test-stream-2", [event, event, event])

      auto_assert(
        [
          %EventstoreSqlite.RecordedEvent{stream_id: "$all", stream_version: 0},
          %EventstoreSqlite.RecordedEvent{stream_id: "$all", stream_version: 1},
          %EventstoreSqlite.RecordedEvent{stream_id: "$all", stream_version: 2},
          %EventstoreSqlite.RecordedEvent{stream_id: "$all", stream_version: 3},
          %EventstoreSqlite.RecordedEvent{stream_id: "$all", stream_version: 4},
          %EventstoreSqlite.RecordedEvent{stream_id: "$all", stream_version: 5}
        ] <- Subscriber.events(all_0)
      )

      auto_assert(
        [%EventstoreSqlite.RecordedEvent{stream_id: "$all", stream_version: 5}] <-
          Subscriber.events(all_5)
      )
    end
  end
end
