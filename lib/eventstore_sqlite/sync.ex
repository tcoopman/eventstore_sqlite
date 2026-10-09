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
  alias EventstoreSqlite.RepoWrite
  alias EventstoreSqlite.Sync.Log
  alias EventstoreSqlite.Sync.State
  alias EventstoreSqlite.SystemEvents.SyncDisabled
  alias EventstoreSqlite.SystemEvents.SyncEnabled

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
