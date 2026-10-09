defmodule EventstoreSqlite.Sync.State do
  @moduledoc false

  alias Ecto.Adapters.SQL
  alias EventstoreSqlite.Store
  alias EventstoreSqlite.Sync.Selector
  alias EventstoreSqlite.SystemEvents.NodeDiverged
  alias EventstoreSqlite.SystemEvents.NodeRetired
  alias EventstoreSqlite.SystemEvents.OwnershipAssigned
  alias EventstoreSqlite.SystemEvents.OwnershipReleased
  alias EventstoreSqlite.SystemEvents.OwnershipRevoked
  alias EventstoreSqlite.SystemEvents.PeerAdded
  alias EventstoreSqlite.SystemEvents.PeerRemoved
  alias EventstoreSqlite.SystemEvents.ReleaseIgnored
  alias EventstoreSqlite.SystemEvents.SnapshotClaimed
  alias EventstoreSqlite.SystemEvents.SnapshotCreated
  alias EventstoreSqlite.SystemEvents.SyncDisabled
  alias EventstoreSqlite.SystemEvents.SyncEnabled
  alias EventstoreSqlite.SystemEvents.SyncHalted
  alias EventstoreSqlite.SystemEvents.SyncResumed

  @sync_stream "$sync"
  @ownership_stream "$ownership"

  defstruct enabled: false,
            node_id: nil,
            home: nil,
            sync_id: nil,
            peers: %{},
            owners: %{},
            revoked: %{},
            retired: %{},
            released: %{},
            halted: %{},
            diverged: nil,
            snapshot: nil

  def sync_stream, do: @sync_stream
  def ownership_stream, do: @ownership_stream

  def apply(%__MODULE__{} = state, %SyncEnabled{} = event) do
    %{
      state
      | enabled: true,
        node_id: event.node_id,
        home: event.home,
        sync_id: event.sync_id,
        peers: %{},
        halted: %{},
        diverged: nil,
        snapshot: nil
    }
  end

  def apply(state, %SyncDisabled{}), do: %{state | enabled: false, peers: %{}, halted: %{}, snapshot: nil}

  def apply(state, %PeerAdded{} = event) do
    %{state | peers: Map.put_new(state.peers, event.node_id, %{pinned_seq: event.pinned_seq}), snapshot: nil}
  end

  def apply(state, %PeerRemoved{} = event) do
    %{
      state
      | peers: Map.delete(state.peers, event.node_id),
        halted: Map.delete(state.halted, event.node_id),
        snapshot: nil
    }
  end

  def apply(state, %SnapshotCreated{} = event), do: %{state | snapshot: event}

  def apply(state, %SnapshotClaimed{} = event) do
    %{
      state
      | node_id: event.node_id,
        peers: %{event.snapshot_of => %{pinned_seq: 0}},
        halted: %{},
        diverged: nil,
        snapshot: nil
    }
  end

  def apply(state, %SyncHalted{} = event) do
    %{state | halted: Map.put(state.halted, event.peer, event.reason), snapshot: nil}
  end

  def apply(state, %SyncResumed{} = event), do: %{state | halted: Map.delete(state.halted, event.peer), snapshot: nil}

  def apply(state, %NodeDiverged{} = event) do
    %{state | diverged: %{revoked_by: event.revoked_by, revoke_seq: event.revoke_seq}, snapshot: nil}
  end

  def apply(state, %OwnershipAssigned{} = event) do
    %{state | owners: Map.put(state.owners, event.generation, %{selector: event.selector, owner: event.to})}
  end

  def apply(state, %OwnershipReleased{} = event) do
    %{
      state
      | owners: Map.delete(state.owners, event.generation),
        released: Map.put(state.released, event.generation, %{owner: event.from, release_seq: event.release_seq})
    }
  end

  def apply(state, %ReleaseIgnored{}), do: state

  def apply(state, %OwnershipRevoked{} = event) do
    %{
      state
      | owners: Map.delete(state.owners, event.generation),
        revoked:
          Map.put(state.revoked, event.generation, %{selector: event.selector, from: event.from, cutoff: event.cutoff})
    }
  end

  def apply(state, %NodeRetired{} = event) do
    %{state | retired: Map.put(state.retired, event.node_id, event.revoke_seq)}
  end

  @doc """
  The state a store's `"$sync"` and `"$ownership"` events replay to. The two
  streams are independent, so replaying one after the other is exact.
  """
  def replay(sync_events, ownership_events) do
    Enum.reduce(sync_events ++ ownership_events, %__MODULE__{}, &__MODULE__.apply(&2, &1))
  end

  def rebuild(repo) do
    replay(Store.system_stream_data(repo, @sync_stream), Store.system_stream_data(repo, @ownership_stream))
  end

  @doc """
  The persisted state. A store whose sync migration hasn't run yet has sync
  disabled.
  """
  def load(repo) do
    case SQL.query(repo, "SELECT value FROM sync_state WHERE key = 'state'") do
      {:ok, %{rows: [[value]]}} -> :erlang.binary_to_term(value)
      {:ok, %{rows: []}} -> %__MODULE__{}
      {:error, %Exqlite.Error{message: "no such table: sync_state"}} -> %__MODULE__{}
      {:error, error} -> raise error
    end
  end

  def save(repo, %__MODULE__{} = state) do
    SQL.query!(repo, "INSERT OR REPLACE INTO sync_state (key, value) VALUES ('state', ?1)", [
      {:blob, :erlang.term_to_binary(state)}
    ])

    state
  end

  @doc """
  Appends `event` to its system stream and returns the state with the event
  applied. Callers persist the state with `save/2` before their transaction
  commits.
  """
  def record(repo, state, event) do
    :ok = Store.append_system_event(repo, stream_for(event), event)
    __MODULE__.apply(state, event)
  end

  defp stream_for(%type{})
       when type in [OwnershipAssigned, OwnershipReleased, ReleaseIgnored, OwnershipRevoked, NodeRetired],
       do: @ownership_stream

  defp stream_for(_event), do: @sync_stream

  def home?(%__MODULE__{} = state), do: state.enabled and state.node_id == state.home

  @doc """
  The node allowed to write `stream_id`, and the generation that allows it.
  Assignments are disjoint, so at most one matches; without one, the home node
  owns the stream under generation 0.
  """
  def owner(%__MODULE__{} = state, stream_id) do
    Enum.find_value(state.owners, {state.home, 0}, fn {generation, %{selector: selector, owner: owner}} ->
      if Selector.matches?(selector, stream_id), do: {owner, generation}
    end)
  end

  def generations_of(%__MODULE__{} = state, node_id) do
    for {generation, %{owner: ^node_id}} <- state.owners, do: generation
  end
end
