defmodule EventstoreSqlite.Sync do
  @moduledoc """
  Replication between two eventstore_sqlite stores, each running in its own
  node, where every stream has exactly one node allowed to write it.

  The home node enables sync and provisions a second node from a snapshot of
  its database. Both nodes then hold every event: each node pulls the entries
  the other one wrote, in order, over Erlang distribution. Which node may write
  a stream is decided by `EventstoreSqlite.Ownership`; by default the home node
  owns everything.

  The store records sync state as system events: `"$sync"` holds identity,
  enablement and peers, and `"$ownership"` holds ownership changes. Both are
  local to each node, like `"$all"`, and neither appears in `"$all"`.

  Configure the node id of each node:

      config :eventstore_sqlite, :sync, node_id: "main-node"

  The store refuses to start when its database belongs to another node id.
  """

  alias Ecto.Adapters.SQL
  alias EventstoreSqlite.RepoRead
  alias EventstoreSqlite.RepoWrite
  alias EventstoreSqlite.Sync.Log
  alias EventstoreSqlite.Sync.State
  alias EventstoreSqlite.SystemEvents.SyncDisabled
  alias EventstoreSqlite.SystemEvents.SyncEnabled
  alias EventstoreSqlite.SystemEvents.SyncHalted
  alias EventstoreSqlite.SystemEvents.SyncResumed

  require Logger

  @doc """
  Enables sync on this store and makes it the home node of a new replication
  group. `node_id` must equal the configured node id.

  Returns `{:error, :already_enabled}` when sync is enabled, and
  `{:error, {:node_id_not_configured, configured}}` when `node_id` isn't the
  configured one. Sync can be enabled again after `disable/0`; that starts a
  new group.
  """
  def enable(node_id) when is_binary(node_id) do
    configured = configured_node_id()

    if configured == node_id do
      transact_state(fn repo, state ->
        cond do
          state.enabled ->
            {:error, :already_enabled}

          state.snapshot ->
            {:error, :unclaimed_snapshot}

          true ->
            SQL.query!(repo, "DELETE FROM sync_acks")
            SQL.query!(repo, "DELETE FROM sync_cursors")
            event = %SyncEnabled{node_id: node_id, home: node_id, sync_id: Ecto.UUID.generate()}
            {:ok, State.record(repo, state, event)}
        end
      end)
    else
      {:error, {:node_id_not_configured, configured}}
    end
  end

  @doc """
  Disables sync on the home node and deletes its log. Requires that no peer
  remains and no stream is assigned to another node.

  Returns `{:error, :sync_disabled | :not_home | :diverged | :peers_remaining |
  :assignments_remaining}` otherwise.
  """
  def disable do
    transact_state(fn repo, state ->
      with :ok <- guard_home(state) do
        cond do
          map_size(state.peers) > 0 ->
            {:error, :peers_remaining}

          map_size(state.owners) > 0 ->
            {:error, :assignments_remaining}

          true ->
            state = State.record(repo, state, %SyncDisabled{})
            :ok = Log.delete_all(repo)
            {:ok, state}
        end
      end
    end)
  end

  @doc """
  Clears a halt of replication from `peer`, after the cause has been repaired,
  so replication resumes. A halt is recorded when an entry from the peer can't
  be applied, for example a version conflict or an ownership violation.

  Divergence can't be cleared: a diverged node returns `{:error, :diverged}`.
  Returns `{:error, :not_halted}` when replication from `peer` isn't halted.
  """
  def resume(peer) when is_binary(peer) do
    transact_state(fn repo, state ->
      cond do
        state.diverged -> {:error, :diverged}
        not Map.has_key?(state.halted, peer) -> {:error, :not_halted}
        true -> {:ok, State.record(repo, state, %SyncResumed{peer: peer})}
      end
    end)
  end

  @doc """
  The entries that were quarantined instead of applied, oldest first. An entry
  is quarantined when it was written under an ownership generation that was
  revoked by `EventstoreSqlite.Ownership.revoke_node/1` before this node
  imported it.
  """
  def quarantine do
    %{rows: rows} =
      SQL.query!(RepoRead, "SELECT origin, seq, reason, inserted_at, entry FROM sync_quarantine ORDER BY id")

    Enum.map(rows, fn [origin, seq, reason, inserted_at, entry] ->
      %{origin: origin, seq: seq, reason: reason, quarantined_at: inserted_at, entry: :erlang.binary_to_term(entry)}
    end)
  end

  @doc false
  defdelegate export(request), to: EventstoreSqlite.Sync.Export

  @doc false
  def halt(peer, reason) do
    Logger.error("eventstore_sqlite sync: replication from #{peer} halted: #{inspect(reason)}")
    :telemetry.execute([:eventstore_sqlite, :sync, :halt], %{}, %{peer: peer, reason: reason})

    transact_state(fn repo, state ->
      if Map.get(state.halted, peer) == reason or state.diverged do
        {:ok, state}
      else
        {:ok, State.record(repo, state, %SyncHalted{peer: peer, reason: reason})}
      end
    end)
  end

  @doc """
  Rebuilds the derived sync state by replaying `"$sync"` and `"$ownership"`.
  """
  def rebuild_state do
    RepoWrite.transact(fn repo -> {:ok, State.save(repo, State.rebuild(repo))} end, mode: :immediate)
    :ok
  end

  @doc false
  def state, do: State.load(RepoWrite)

  @doc false
  def configured_node_id, do: Keyword.get(Application.get_env(:eventstore_sqlite, :sync, []), :node_id)

  @doc false
  def guard_home(%State{} = state) do
    cond do
      state.diverged -> {:error, :diverged}
      not state.enabled -> {:error, :sync_disabled}
      not State.home?(state) -> {:error, :not_home}
      true -> :ok
    end
  end

  @doc false
  def transact_state(fun) do
    result =
      RepoWrite.transact(
        fn repo ->
          case fun.(repo, State.load(repo)) do
            {:ok, %State{} = state} -> {:ok, {State.save(repo, state), :ok}}
            {:ok, %State{} = state, reply} -> {:ok, {State.save(repo, state), reply}}
            {:error, _} = error -> error
          end
        end,
        mode: :immediate
      )

    case result do
      {:ok, {state, reply}} ->
        after_state_change(state)
        reply

      error ->
        error
    end
  end

  defp after_state_change(state) do
    EventstoreSqlite.Subscriptions.ping(State.sync_stream())
    EventstoreSqlite.Subscriptions.ping(State.ownership_stream())
    if state.enabled, do: EventstoreSqlite.Sync.Write.poke(state.node_id)
    EventstoreSqlite.Sync.Server.refresh()
  end
end
