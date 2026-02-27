defmodule EventstoreSqlite.Subscriptions do
  @moduledoc false
  use GenServer
  # Client

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  def subscribe_to_stream(subscriber_pid, stream, version \\ 0, filter \\ nil) do
    GenServer.call(__MODULE__, {:subscribe_to_stream, subscriber_pid, stream, version, filter})
  end

  def ping(stream) do
    GenServer.cast(__MODULE__, {:ping, stream})
  end

  # Server (callbacks)

  @impl true
  def init(_) do
    {:ok,
     %{
       subscribed_streams: %{},
       subscribers: %{},
       streams_to_handle: :queue.new()
     }}
  end

  @impl true
  def handle_call({:subscribe_to_stream, subscriber_pid, stream, version, filter}, _from, state) do
    state =
      state
      |> update_subscribed_streams(stream, version)
      |> update_subscribers(subscriber_pid, stream, version, filter)
      |> update_streams_to_handle(stream)

    {:reply, :ok, state, {:continue, :handle_stream}}
  end

  @impl true
  def handle_cast({:ping, stream}, state) do
    state = state |> update_streams_to_handle(stream) |> update_streams_to_handle("$all")
    {:noreply, state, {:continue, :handle_stream}}
  end

  @impl true
  def handle_continue(:handle_stream, state) do
    {stream, streams_to_handle} = :queue.out(state.streams_to_handle)

    case stream do
      {:value, stream} ->
        state = send_to_stream(state, stream)
        state = %{state | streams_to_handle: streams_to_handle}
        {:noreply, state, {:continue, :handle_stream}}

      :empty ->
        {:noreply, state}
    end
  end

  defp update_streams_to_handle(state, stream) do
    cond do
      Map.has_key?(state.subscribers, stream) == false ->
        state

      :queue.member(stream, state.streams_to_handle) ->
        state

      true ->
        %{state | streams_to_handle: :queue.in(stream, state.streams_to_handle)}
    end
  end

  defp update_subscribed_streams(state, stream, version) do
    subscribed_streams =
      Map.update(state.subscribed_streams, stream, version, fn old_version ->
        if old_version < version, do: old_version, else: version
      end)

    %{state | subscribed_streams: subscribed_streams}
  end

  defp update_subscribers(state, subscriber_pid, stream, version, filter) do
    subscribers =
      Map.update(state.subscribers, stream, [{subscriber_pid, version, filter}], fn other ->
        [{subscriber_pid, version, filter} | other]
      end)

    %{state | subscribers: subscribers}
  end

  defp send_to_stream(state, stream) do
    version_to_read = Map.get(state.subscribed_streams, stream, 0)
    events = EventstoreSqlite.read_stream_forward({stream, version_to_read})

    new_version_to_read =
      case List.last(events) do
        nil -> version_to_read
        e -> e.stream_version + 1
      end

    subscribers = Map.get(state.subscribers, stream, [])

    subscribers =
      Enum.map(subscribers, fn {subscriber_pid, version, filter} ->
        events =
          Enum.filter(events, fn event ->
            event.stream_version >= version
          end)

        case events do
          [] -> :ok
          _ -> send(subscriber_pid, {:events, events})
        end

        new_version = if version > new_version_to_read, do: version, else: new_version_to_read

        {subscriber_pid, new_version, filter}
      end)

    %{
      state
      | subscribers: Map.put(state.subscribers, stream, subscribers),
        subscribed_streams: Map.put(state.subscribed_streams, stream, new_version_to_read)
    }
  end
end
