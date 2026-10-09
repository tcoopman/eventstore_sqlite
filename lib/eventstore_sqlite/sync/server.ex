defmodule EventstoreSqlite.Sync.Server do
  @moduledoc false
  use GenServer

  alias EventstoreSqlite.RepoWrite
  alias EventstoreSqlite.Sync
  alias EventstoreSqlite.Sync.Boot
  alias EventstoreSqlite.Sync.Replicator
  alias EventstoreSqlite.Sync.Snapshot
  alias EventstoreSqlite.Sync.State
  alias EventstoreSqlite.Sync.Write

  require Logger

  @replicators EventstoreSqlite.Sync.ReplicatorSupervisor
  @check_interval 5_000

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def refresh do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid when pid == self() -> :ok
      _pid -> GenServer.call(__MODULE__, :refresh, 30_000)
    end
  end

  def snapshot(path, peer), do: GenServer.call(__MODULE__, {:snapshot, path, peer}, :infinity)

  @impl true
  def init(_) do
    configured = Sync.configured_node_id()

    result =
      case Boot.check(RepoWrite, configured) do
        :ok -> :ok
        {:claim, snapshot} -> Snapshot.claim(snapshot, configured)
        {:error, message} -> {:error, message}
      end

    case result do
      :ok ->
        schedule_check()
        {:ok, sync_processes(%{node_id: nil})}

      {:error, message} ->
        Logger.error("eventstore_sqlite sync: " <> message)
        {:stop, {:sync_identity, message}}
    end
  end

  @impl true
  def handle_call(:refresh, _from, state), do: {:reply, :ok, sync_processes(state)}

  def handle_call({:snapshot, path, peer}, _from, state) do
    reply = Snapshot.create(path, peer)
    {:reply, reply, sync_processes(state)}
  end

  @impl true
  def handle_info(:check, state) do
    schedule_check()
    {:noreply, sync_processes(state)}
  end

  defp schedule_check, do: Process.send_after(self(), :check, @check_interval)

  defp sync_processes(server) do
    sync = State.load(RepoWrite)
    node_id = if sync.enabled, do: sync.node_id
    server = advertise(server, node_id)

    wanted = if node_id, do: Map.keys(sync.peers), else: []
    running = for {_, pid, _, _} <- DynamicSupervisor.which_children(@replicators), do: {peer_of(pid), pid}

    for {peer, pid} <- running, peer not in wanted, do: DynamicSupervisor.terminate_child(@replicators, pid)

    for peer <- wanted, not Enum.any?(running, &(elem(&1, 0) == peer)) do
      {:ok, _} = DynamicSupervisor.start_child(@replicators, {Replicator, peer})
    end

    for peer <- wanted, do: Replicator.pull_now(peer)
    server
  end

  defp peer_of(pid) do
    case Registry.keys(EventstoreSqlite.Sync.Registry, pid) do
      [peer] -> peer
      [] -> nil
    end
  end

  defp advertise(%{node_id: node_id} = server, node_id), do: server

  defp advertise(server, node_id) do
    if server.node_id, do: :pg.leave(Write.pg_scope(), {:node, server.node_id}, self())
    if node_id, do: :pg.join(Write.pg_scope(), {:node, node_id}, self())
    %{server | node_id: node_id}
  end
end
