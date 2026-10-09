defmodule EventstoreSqlite.Sync.Replicator do
  @moduledoc false
  use GenServer

  alias EventstoreSqlite.RepoRead
  alias EventstoreSqlite.Sync
  alias EventstoreSqlite.Sync.Export
  alias EventstoreSqlite.Sync.Import
  alias EventstoreSqlite.Sync.State
  alias EventstoreSqlite.Sync.Write

  require Logger

  @idle_interval 1_000
  @fenced_interval 1_000
  @min_backoff 100
  @max_backoff 5_000
  @max_entries 500
  @max_bytes 8_000_000
  @export_timeout 15_000

  def start_link(peer), do: GenServer.start_link(__MODULE__, peer, name: via(peer))

  def via(peer), do: {:via, Registry, {EventstoreSqlite.Sync.Registry, peer}}

  def status(peer) do
    GenServer.call(via(peer), :status, 1_000)
  catch
    :exit, _ -> %{connection: :not_running, last_error: nil, last_success: nil}
  end

  def pull_now(peer) do
    case Registry.lookup(EventstoreSqlite.Sync.Registry, peer) do
      [{pid, _}] -> send(pid, :sync_poke)
      [] -> :ok
    end

    :ok
  end

  @impl true
  def init(peer) do
    :ok = :pg.join(Write.pg_scope(), {:replicator, peer}, self())
    {_ref, _members} = :pg.monitor(Write.pg_scope(), {:node, peer})
    EventstoreSqlite.Subscriptions.ping_all()
    send(self(), :pull)

    {:ok, %{peer: peer, connection: :disconnected, last_error: nil, last_success: nil, backoff: @min_backoff, timer: nil}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, Map.take(state, [:connection, :last_error, :last_success]), state}
  end

  @impl true
  def handle_info(:pull, state), do: {:noreply, pull(%{state | timer: nil})}

  def handle_info(:sync_poke, state), do: {:noreply, pull_soon(state)}

  def handle_info({_ref, :join, _group, _pids}, state), do: {:noreply, pull_soon(state)}

  def handle_info({_ref, :leave, _group, _pids}, state), do: {:noreply, state}

  defp pull_soon(%{timer: nil} = state), do: schedule(state, 0)

  defp pull_soon(state) do
    Process.cancel_timer(state.timer)
    schedule(%{state | timer: nil}, 0)
  end

  defp schedule(state, after_ms), do: %{state | timer: Process.send_after(self(), :pull, after_ms)}

  defp pull(state) do
    sync = State.load(RepoRead)

    cond do
      sync.diverged -> fenced(state, :diverged)
      not sync.enabled -> fenced(state, :sync_disabled)
      not Map.has_key?(sync.peers, state.peer) -> fenced(state, :not_a_peer)
      Map.has_key?(sync.halted, state.peer) -> fenced(state, :halted)
      true -> pull_from(state, sync)
    end
  end

  defp fenced(state, connection), do: schedule(%{state | connection: connection}, @fenced_interval)

  defp pull_from(state, sync) do
    case :pg.get_members(Write.pg_scope(), {:node, state.peer}) do
      [] ->
        backoff(%{state | connection: :disconnected}, :peer_not_connected)

      [pid] ->
        request(state, sync, node(pid))

      pids ->
        backoff(%{state | connection: :ambiguous}, {:several_nodes_claim, state.peer, Enum.map(pids, &node/1)})
    end
  end

  defp request(state, sync, peer_node) do
    request = %{
      protocol: Export.protocol(),
      sync_id: sync.sync_id,
      from: sync.node_id,
      expect: state.peer,
      after_seq: Import.cursor(RepoRead, state.peer),
      max_entries: @max_entries,
      max_bytes: @max_bytes
    }

    case :erpc.call(peer_node, Sync, :export, [request], @export_timeout) do
      {:ok, response} -> apply_response(state, response)
      {:error, reason} -> halt(state, reason)
    end
  catch
    :error, {:erpc, reason} -> backoff(%{state | connection: :disconnected}, {:erpc, reason})
    :exit, reason -> backoff(%{state | connection: :disconnected}, {:exit, reason})
  end

  defp apply_response(state, response) do
    started = System.monotonic_time()
    result = Import.import_entries(state.peer, response.entries, %{head: response.head, diverged: response.diverged})

    case result do
      {:ok, %{cursor: cursor}} ->
        emit_import(state.peer, response, started, cursor)
        state = %{state | connection: :connected, last_success: DateTime.utc_now(), backoff: @min_backoff}

        if response.entries != [] and cursor < response.head,
          do: schedule(state, 0),
          else: schedule(state, @idle_interval)

      {:diverged, _} ->
        fenced(%{state | last_error: :diverged}, :diverged)

      {:halt, reason, _} ->
        fenced(%{state | last_error: reason}, :halted)

      {:fenced, reason} ->
        fenced(%{state | last_error: reason}, :halted)
    end
  rescue
    error ->
      Logger.error("eventstore_sqlite sync: importing from #{state.peer} failed: " <> Exception.message(error))
      backoff(state, {:import_failed, Exception.message(error)})
  end

  defp halt(state, reason) do
    Sync.halt(state.peer, reason)
    fenced(%{state | last_error: reason}, :halted)
  end

  defp backoff(state, error) do
    state = schedule(%{state | last_error: error}, state.backoff)
    %{state | backoff: min(state.backoff * 2, @max_backoff)}
  end

  defp emit_import(peer, response, started, cursor) do
    if response.entries != [] do
      :telemetry.execute(
        [:eventstore_sqlite, :sync, :import],
        %{
          entries: length(response.entries),
          events: Enum.sum_by(response.entries, &length(&1.events)),
          duration: System.monotonic_time() - started
        },
        %{peer: peer}
      )
    end

    :telemetry.execute([:eventstore_sqlite, :sync, :lag], %{entries: response.head - cursor}, %{peer: peer})
  end
end
