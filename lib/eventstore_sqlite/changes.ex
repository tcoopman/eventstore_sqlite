defmodule EventstoreSqlite.Changes do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def subscribe(pid) when is_pid(pid), do: GenServer.call(__MODULE__, {:subscribe, pid})

  @doc """
  Records that something of `kinds` changed. Never blocks the caller.
  """
  def notify(kinds), do: GenServer.cast(__MODULE__, {:changed, MapSet.new(List.wrap(kinds))})

  @impl true
  def init(_) do
    {:ok, %{interval: Application.get_env(:eventstore_sqlite, :changes_interval, 1_000), subscribers: %{}}}
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    subscribers =
      Map.put_new_lazy(state.subscribers, pid, fn ->
        Process.monitor(pid)
        %{pending: MapSet.new(), timer: nil}
      end)

    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  @impl true
  def handle_cast({:changed, kinds}, state) do
    subscribers =
      Map.new(state.subscribers, fn
        {pid, %{timer: nil} = subscriber} -> {pid, deliver(pid, subscriber, kinds, state.interval)}
        {pid, subscriber} -> {pid, %{subscriber | pending: MapSet.union(subscriber.pending, kinds)}}
      end)

    {:noreply, %{state | subscribers: subscribers}}
  end

  @impl true
  def handle_info({:window_closed, pid}, state) do
    case state.subscribers do
      %{^pid => subscriber} ->
        subscriber =
          if MapSet.size(subscriber.pending) == 0,
            do: %{subscriber | timer: nil},
            else: deliver(pid, subscriber, subscriber.pending, state.interval)

        {:noreply, put_in(state.subscribers[pid], subscriber)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}
  end

  defp deliver(pid, subscriber, kinds, interval) do
    send(pid, {:eventstore_sqlite, :changed, kinds |> MapSet.to_list() |> Enum.sort()})
    %{subscriber | pending: MapSet.new(), timer: Process.send_after(self(), {:window_closed, pid}, interval)}
  end
end
