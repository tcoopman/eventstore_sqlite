defmodule EventstoreSqlite.SubscriptionRestartTest do
  use ExUnit.Case
  use EventstoreSqlite.DataCase

  alias EventstoreSqlite.Test.Note

  defmodule DocumentedSubscriber do
    @moduledoc false
    use GenServer

    def start_link(stream), do: GenServer.start_link(__MODULE__, stream)

    def handled(pid), do: GenServer.call(pid, :handled)

    @impl true
    def init(stream) do
      {:ok, subscribe(%{stream: stream, version: 0, handled: []})}
    end

    defp subscribe(state) do
      ref = Process.monitor(EventstoreSqlite.Subscriptions)
      :ok = EventstoreSqlite.subscribe_to_stream(self(), state.stream, state.version)
      Map.put(state, :ref, ref)
    end

    @impl true
    def handle_call(:handled, _from, state), do: {:reply, Enum.reverse(state.handled), state}

    @impl true
    def handle_info({:events, events}, state) do
      new = Enum.filter(events, &(&1.stream_version >= state.version))
      handled = Enum.reduce(new, state.handled, &[&1.data.text | &2])
      version = if new == [], do: state.version, else: List.last(new).stream_version + 1
      {:noreply, %{state | version: version, handled: handled}}
    end

    def handle_info({:DOWN, ref, :process, _pid, _reason}, %{ref: ref} = state) do
      Process.send_after(self(), :resubscribe, 100)
      {:noreply, state}
    end

    def handle_info(:resubscribe, state) do
      {:noreply, subscribe(state)}
    catch
      :exit, _not_restarted_yet ->
        Process.send_after(self(), :resubscribe, 100)
        {:noreply, state}
    end
  end

  defp note(text), do: %Note{text: text}

  defp wait_for(fun, attempts \\ 100) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition never became true")
      true -> pause_and_retry(fun, attempts)
    end
  end

  defp pause_and_retry(fun, attempts) do
    Process.sleep(20)
    wait_for(fun, attempts - 1)
  end

  test "a subscriber following the documented pattern misses nothing when the subscription process restarts" do
    {:ok, subscriber} = DocumentedSubscriber.start_link("orders:1")
    :ok = EventstoreSqlite.subscribe_to_stream(self(), "orders:1")
    :ok = EventstoreSqlite.append_to_stream("orders:1", [note("a"), note("b")])
    wait_for(fn -> DocumentedSubscriber.handled(subscriber) == ["a", "b"] end)

    old = Process.whereis(EventstoreSqlite.Subscriptions)
    Process.exit(old, :kill)
    :ok = EventstoreSqlite.append_to_stream("orders:1", [note("c")])
    wait_for(fn -> Process.whereis(EventstoreSqlite.Subscriptions) not in [nil, old] end)
    :ok = EventstoreSqlite.append_to_stream("orders:1", [note("d")])

    wait_for(fn -> DocumentedSubscriber.handled(subscriber) == ["a", "b", "c", "d"] end)

    assert_received {:events, [%{data: %{text: "a"}}, %{data: %{text: "b"}}]}
    refute_received {:events, _}, "a subscriber that doesn't monitor misses everything after the restart"
  end
end
