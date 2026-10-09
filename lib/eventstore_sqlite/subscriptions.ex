defmodule EventstoreSqlite.Subscriptions do
  @moduledoc false
  use GenServer

  import Ecto.Query, only: [from: 2]

  # Client
  alias EventstoreSqlite.Sync.Failpoint

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @default_batch_size 10_000

  def subscribe_to_stream(subscriber_pid, stream, version \\ 0, filter \\ nil, batch_size \\ @default_batch_size) do
    GenServer.call(__MODULE__, {:subscribe_to_stream, subscriber_pid, stream, version, filter, batch_size})
  end

  def ping(stream) do
    GenServer.cast(__MODULE__, {:ping, stream})
  end

  def archive_stream(stream, archive) do
    case GenServer.call(__MODULE__, {:archive_stream, stream, archive}, :infinity) do
      {:raised, kind, reason, stacktrace} -> :erlang.raise(kind, reason, stacktrace)
      result -> result
    end
  end

  @doc """
  Runs an imported archive entry. `apply` opens its own transaction and returns
  `{:ok, :applied | :duplicate | :quarantined}` or an error. Only `:applied`
  ends the stream's subscriptions.
  """
  def apply_archive(stream, apply) do
    case GenServer.call(__MODULE__, {:apply_archive, stream, apply}, :infinity) do
      {:raised, kind, reason, stacktrace} -> :erlang.raise(kind, reason, stacktrace)
      result -> result
    end
  end

  @doc """
  Checks every subscribed stream for events that weren't delivered, as the
  periodic reconciliation does.
  """
  def ping_all do
    GenServer.cast(__MODULE__, :ping_all)
  end

  # Server (callbacks)

  @impl true
  def init(_) do
    schedule_reconcile()

    {:ok,
     %{
       subscribed_streams: %{},
       subscribers: %{},
       streams_to_handle: :queue.new(),
       monitors: %{}
     }}
  end

  @impl true
  def handle_call({:subscribe_to_stream, subscriber_pid, stream, version, filter, batch_size}, _from, state) do
    version = resolve_version(stream, version)

    state =
      state
      |> monitor_subscriber(subscriber_pid)
      |> update_subscribed_streams(stream, version)
      |> update_subscribers(subscriber_pid, stream, version, filter, batch_size)
      |> update_streams_to_handle(stream)

    {:reply, :ok, state, {:continue, :handle_stream}}
  end

  def handle_call({:archive_stream, stream, archive}, _from, state) do
    case run_archive(archive) do
      {:ok, result} ->
        Failpoint.hit(:archive_after_commit)
        state = state |> end_subscriptions(stream) |> update_streams_to_handle("$archives")
        {:reply, {:ok, result}, state, {:continue, :handle_stream}}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:apply_archive, stream, apply}, _from, state) do
    case run_archive(apply) do
      {:ok, :applied} ->
        Failpoint.hit(:archive_after_commit)
        state = state |> end_subscriptions(stream) |> update_streams_to_handle("$archives")
        {:reply, {:ok, :applied}, state, {:continue, :handle_stream}}

      result ->
        {:reply, result, state}
    end
  end

  @impl true
  def handle_cast({:ping, stream}, state) do
    state = state |> update_streams_to_handle(stream) |> update_streams_to_handle("$all")
    {:noreply, state, {:continue, :handle_stream}}
  end

  def handle_cast(:ping_all, state) do
    state = Enum.reduce(Map.keys(state.subscribers), state, &update_streams_to_handle(&2, &1))
    {:noreply, state, {:continue, :handle_stream}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, remove_subscriber(state, pid)}
  end

  def handle_info(:reconcile, state) do
    schedule_reconcile()
    state = Enum.reduce(streams_behind(state.subscribed_streams), state, &update_streams_to_handle(&2, &1))
    {:noreply, state, {:continue, :handle_stream}}
  end

  @impl true
  def handle_continue(:handle_stream, state) do
    {stream, streams_to_handle} = :queue.out(state.streams_to_handle)

    case stream do
      {:value, stream} ->
        state = send_to_stream(%{state | streams_to_handle: streams_to_handle}, stream)
        {:noreply, state, {:continue, :handle_stream}}

      :empty ->
        {:noreply, state}
    end
  end

  defp schedule_reconcile do
    Process.send_after(
      self(),
      :reconcile,
      Application.get_env(:eventstore_sqlite, :subscription_reconcile_interval, 1_000)
    )
  end

  defp streams_behind(subscribed_streams) when map_size(subscribed_streams) == 0, do: []

  defp streams_behind(subscribed_streams) do
    subscribed_streams
    |> Map.keys()
    |> Enum.chunk_every(500)
    |> Enum.flat_map(fn streams ->
      EventstoreSqlite.RepoRead.all(
        from(s in "streams", where: s.stream_id in ^streams, select: {s.stream_id, s.stream_version})
      )
    end)
    |> Enum.filter(fn {stream, version} -> version > Map.fetch!(subscribed_streams, stream) end)
    |> Enum.map(&elem(&1, 0))
  end

  # `streams.stream_version` is the number of events in the stream, which is the
  # version the next event will get — so it is exactly "everything after now".
  defp resolve_version(stream, :current) do
    query = from(s in "streams", where: s.stream_id == ^stream, select: s.stream_version)

    EventstoreSqlite.RepoRead.one(query) || 0
  end

  defp resolve_version(_stream, version) when is_integer(version), do: version

  defp run_archive(archive) do
    archive.()
  catch
    kind, reason -> {:raised, kind, reason, __STACKTRACE__}
  end

  defp end_subscriptions(state, stream) do
    {subscribers, remaining} = Map.pop(state.subscribers, stream, [])

    Enum.each(subscribers, fn {pid, _version, _filter, _batch_size} -> send(pid, {:stream_archived, stream}) end)

    state = %{state | subscribers: remaining, subscribed_streams: Map.delete(state.subscribed_streams, stream)}

    subscribers
    |> Enum.map(fn {pid, _version, _filter, _batch_size} -> pid end)
    |> Enum.uniq()
    |> Enum.reduce(state, &demonitor_if_unsubscribed/2)
  end

  defp demonitor_if_unsubscribed(pid, state) do
    subscribed? =
      Enum.any?(state.subscribers, fn {_stream, subs} ->
        Enum.any?(subs, fn {sub_pid, _version, _filter, _batch_size} -> sub_pid == pid end)
      end)

    if subscribed? do
      state
    else
      {ref, monitors} = Map.pop(state.monitors, pid)
      Process.demonitor(ref, [:flush])
      %{state | monitors: monitors}
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

  defp monitor_subscriber(state, subscriber_pid) do
    if Map.has_key?(state.monitors, subscriber_pid) do
      state
    else
      ref = Process.monitor(subscriber_pid)
      %{state | monitors: Map.put(state.monitors, subscriber_pid, ref)}
    end
  end

  defp remove_subscriber(state, pid) do
    {emptied_streams, subscribers} =
      Enum.reduce(state.subscribers, {[], %{}}, fn {stream, subs}, {emptied, acc} ->
        case Enum.reject(subs, fn {sub_pid, _version, _filter, _batch_size} -> sub_pid == pid end) do
          [] -> {[stream | emptied], acc}
          subs -> {emptied, Map.put(acc, stream, subs)}
        end
      end)

    %{
      state
      | subscribers: subscribers,
        subscribed_streams: Map.drop(state.subscribed_streams, emptied_streams),
        monitors: Map.delete(state.monitors, pid)
    }
  end

  defp update_subscribers(state, subscriber_pid, stream, version, filter, batch_size) do
    subscriber = {subscriber_pid, version, filter, batch_size}

    subscribers =
      Map.update(state.subscribers, stream, [subscriber], fn other ->
        [subscriber | other]
      end)

    %{state | subscribers: subscribers}
  end

  defp send_to_stream(state, stream) do
    case Map.get(state.subscribers, stream, []) do
      [] -> state
      subscribers -> send_to_stream(state, stream, subscribers)
    end
  end

  defp send_to_stream(state, stream, subscribers) do
    version_to_read = Map.get(state.subscribed_streams, stream, 0)
    batch_size = subscribers |> Enum.map(fn {_pid, _version, _filter, batch_size} -> batch_size end) |> Enum.min()
    events = EventstoreSqlite.read_stream_forward({stream, version_to_read}, count: batch_size)

    new_version_to_read =
      case List.last(events) do
        nil -> version_to_read
        e -> e.stream_version + 1
      end

    subscribers =
      Enum.map(subscribers, fn {subscriber_pid, version, filter, subscriber_batch_size} ->
        events =
          Enum.filter(events, fn event ->
            event.stream_version >= version
          end)

        case events do
          [] -> :ok
          _ -> send(subscriber_pid, {:events, events})
        end

        new_version = if version > new_version_to_read, do: version, else: new_version_to_read

        {subscriber_pid, new_version, filter, subscriber_batch_size}
      end)

    state = %{
      state
      | subscribers: Map.put(state.subscribers, stream, subscribers),
        subscribed_streams: Map.put(state.subscribed_streams, stream, new_version_to_read)
    }

    if length(events) == batch_size, do: update_streams_to_handle(state, stream), else: state
  end
end
