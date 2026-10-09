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

  ## Lifecycle

  On the home node:

      :ok = EventstoreSqlite.Sync.enable("main-node")
      {:ok, _} = EventstoreSqlite.Sync.snapshot("secondary.db", peer: "secondary-node-1")

  Start the second node on `secondary.db` with `node_id: "secondary-node-1"`
  and connect the nodes over Erlang distribution (for example with
  libcluster). The nodes find each other by node id; the second node pulls
  everything written since the snapshot, and the home node pulls from it.
  Each node's subscribers receive the other node's events like local ones.

  Then move writing of some streams to the second node, and back:

      {:ok, generation} = EventstoreSqlite.Ownership.assign("venue:*", "secondary-node-1")
      :ok = EventstoreSqlite.Ownership.reclaim(generation)

  When the second node is gone for good while it owns streams, take them back
  without it with `EventstoreSqlite.Ownership.revoke_node/1`. To end: remove
  the peer with `remove_peer/2`, then `disable/0`.

  ## Guarantees

    * A stream has one writer: a node that doesn't own a stream gets
      `{:error, :not_owner}`. The one exception is a forced reclaim during a
      partition: the old owner keeps writing until it hears of it, and those
      writes are quarantined, never applied.
    * Stream versions, event ids, timestamps and data are identical on both
      nodes. `"$all"` is per node, in the order events arrived there, so a
      `"$all"` position is only meaningful on the node it came from.
    * Replication is asynchronous: an append returns once it is committed
      locally. A partition or restart only delays replication.
    * An entry that would break the single-writer rule halts replication from
      that peer instead of being applied (`status/0`, `resume/1`).

  ## Cost

  Every append and archive reads the sync state in its transaction, also when
  sync is disabled. Measured on single-event appends:

    * sync disabled: about 18 µs more per append, about 5%;
    * sync enabled: about 28% more, for the ownership check and the change log
      entry written in the same transaction.

  Replication itself runs in the background and doesn't slow appends down, but
  it shares SQLite's single write connection with them.

  `status/0` and `verify/2` are for operators. The design and its review are
  in `docs/issues/0008-multi-node-sync-plan.md`; a manual stress test is in
  `docs/sync-manual-stress-test.md`.
  """

  alias Ecto.Adapters.SQL
  alias EventstoreSqlite.RepoRead
  alias EventstoreSqlite.RepoWrite
  alias EventstoreSqlite.Sync.Export
  alias EventstoreSqlite.Sync.Log
  alias EventstoreSqlite.Sync.Server
  alias EventstoreSqlite.Sync.State
  alias EventstoreSqlite.Sync.Write
  alias EventstoreSqlite.SystemEvents.PeerRemoved
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
  Writes a consistent copy of this store to `path`, for provisioning the node
  `peer` (the `:peer` option). Only the home node can make snapshots, one at a
  time, and only for one peer: a second peer must wait until the first is
  removed with `remove_peer/2`.

  Start the new node on the copy with `config :eventstore_sqlite, :sync,
  node_id: peer`. At its first boot it claims the copy: it takes `peer` as its
  identity and continues replicating from where the copy was made. A copy can
  be claimed once, and only by `peer`.

  The peer is pinned from the moment of the snapshot: the log isn't pruned past
  that point until the peer has pulled it.

  Returns `{:ok, %{path, snapshot_id, head_seq}}`, or `{:error, reason}` with
  `reason` one of `{:exists, path}`, `:not_home`, `:sync_disabled`,
  `:diverged`, `:self`, `:retired`, `{:peer_exists, other}`,
  `:peer_already_active` or `{:snapshot_failed, message}`.
  """
  def snapshot(path, opts) when is_binary(path) do
    peer = Keyword.fetch!(opts, :peer)
    Server.snapshot(path, peer)
  end

  @doc """
  Removes `peer` from the replication group, on the home node.

  The peer must own no streams: release them first (`EventstoreSqlite.Ownership.reclaim/2`)
  or revoke the node (`EventstoreSqlite.Ownership.revoke_node/1`). Then:

    * a live peer must have pulled everything from this node, and this node
      everything the peer reported (`{:error, :not_caught_up}` otherwise);
    * a retired peer must be drained: it reported itself diverged, and this node
      has pulled up to the head it reported then (`{:error, :not_drained}`
      otherwise). Its late entries are then all applied or quarantined.

  A peer's acknowledgement is recorded shortly after its pull, so right after
  it caught up this can return `{:error, :not_caught_up}` for up to about a
  second; retry.

  `discard_unpulled: true` skips those checks, for a peer that is gone for
  good. Whatever it wrote after this node's last pull is lost; the removal
  records the seq after which entries were discarded.

  With no peer left, the log is pruned empty.
  """
  def remove_peer(peer, opts \\ []) when is_binary(peer) do
    discard? = Keyword.get(opts, :discard_unpulled, false)

    transact_state(fn repo, state ->
      with :ok <- guard_home(state),
           :ok <- removable(repo, state, peer, discard?) do
        %{cursor: cursor, head: head} = origin_status(repo, peer)
        discarded_after = if discard? and head != cursor, do: cursor

        if discarded_after do
          Logger.warning("eventstore_sqlite sync: removing #{peer}; entries it wrote after seq #{cursor} are discarded")
        end

        state = State.record(repo, state, %PeerRemoved{node_id: peer, discarded_after: discarded_after})
        SQL.query!(repo, "DELETE FROM sync_acks WHERE peer = ?1", [peer])
        SQL.query!(repo, "DELETE FROM sync_cursors WHERE origin = ?1", [peer])
        Export.prune(repo, state)
        {:ok, state}
      end
    end)
  end

  defp removable(repo, state, peer, discard?) do
    cond do
      not Map.has_key?(state.peers, peer) -> {:error, :unknown_peer}
      State.generations_of(state, peer) != [] -> {:error, :owns_streams}
      discard? -> :ok
      caught_up?(repo, state, peer) -> :ok
      Map.has_key?(state.retired, peer) -> {:error, :not_drained}
      true -> {:error, :not_caught_up}
    end
  end

  defp caught_up?(repo, state, peer) do
    %{cursor: cursor, head: head, diverged: diverged} = origin_status(repo, peer)

    if Map.has_key?(state.retired, peer) do
      diverged and cursor == head
    else
      cursor == head and peer_ack(repo, peer) == Log.head(repo)
    end
  end

  defp origin_status(repo, peer) do
    query = "SELECT seq, origin_head, origin_diverged, applied_at FROM sync_cursors WHERE origin = ?1"

    case SQL.query!(repo, query, [peer]) do
      %{rows: [[seq, head, diverged, applied_at]]} ->
        %{cursor: seq, head: head, diverged: diverged == 1, applied_at: datetime(applied_at)}

      %{rows: []} ->
        %{cursor: 0, head: nil, diverged: false, applied_at: nil}
    end
  end

  defp datetime(nil), do: nil

  defp datetime(text) do
    {:ok, datetime, 0} = DateTime.from_iso8601(text)
    datetime
  end

  defp peer_ack(repo, peer) do
    case SQL.query!(repo, "SELECT seq FROM sync_acks WHERE peer = ?1", [peer]) do
      %{rows: [[seq]]} -> seq
      %{rows: []} -> nil
    end
  end

  @doc """
  The sync state of this node:

    * `node_id`, `home`, `enabled`, `home?` and `diverged` (`nil`, or how this
      node learned it was revoked);
    * `head` — the last seq this node handed out in its change log;
    * `log` — the entries it still retains for its peers: `%{oldest, entries}`,
      with `oldest` `nil` when there are none. Entries are pruned once every
      peer has acknowledged them (`acked`), and never past a peer's
      `pinned_seq`;
    * `assignments` — the active ownership assignments, by generation;
    * `peers` — per peer:
      * `state` — `:connected`, `:disconnected`, `:halted`, `:retired`
        (revoked, not heard from since), `:diverged` (revoked and reported
        itself diverged), `:drained` (diverged and fully pulled),
        `:ambiguous` (several nodes claim the peer's id), `:busy` (its
        replicator didn't answer within a second) or `:not_running`;
      * `cursor` — the last of its entries this node applied, and
        `peer_head`, the last head it reported; `lag` is their difference;
      * `last_applied_at` — when this node last applied one of its entries,
        or `nil`. With `lag` above 0, an old `last_applied_at` means
        replication is stuck rather than busy;
      * `acked` — the last of this node's entries the peer confirmed, and
        `pinned_seq`; the log can't be pruned past the smaller one;
      * `owns` — the ownership generations it holds;
      * `quarantined` — how many of its entries were quarantined;
      * `halted` — why replication from it halted, or `nil`;
      * `last_error`, `last_success` — the replicator's last failure and last
        successful pull. They are kept in memory, so they are `nil` after a
        restart until the next attempt.

  Every timestamp is a `DateTime`. Each peer costs a call to its replicator,
  which waits at most a second.
  """
  def status do
    state = State.load(RepoRead)

    %{
      node_id: state.node_id,
      home: state.home,
      enabled: state.enabled,
      home?: State.home?(state),
      diverged: state.diverged,
      head: Log.head(RepoRead),
      log: Log.retained(RepoRead),
      assignments: state.owners,
      peers: Map.new(state.peers, fn {peer, info} -> {peer, peer_status(state, peer, info)} end)
    }
  end

  defp peer_status(state, peer, info) do
    origin = origin_status(RepoRead, peer)
    replicator = EventstoreSqlite.Sync.Replicator.status(peer)

    %{rows: [[quarantined]]} =
      SQL.query!(RepoRead, "SELECT count(*) FROM sync_quarantine WHERE origin = ?1", [peer])

    connection =
      cond do
        Map.has_key?(state.retired, peer) and origin.diverged and origin.cursor == origin.head -> :drained
        Map.has_key?(state.retired, peer) and origin.diverged -> :diverged
        Map.has_key?(state.retired, peer) -> :retired
        Map.has_key?(state.halted, peer) -> :halted
        true -> replicator.connection
      end

    %{
      state: connection,
      cursor: origin.cursor,
      peer_head: origin.head,
      lag: if(origin.head, do: max(origin.head - origin.cursor, 0)),
      last_applied_at: origin.applied_at,
      acked: peer_ack(RepoRead, peer),
      pinned_seq: info.pinned_seq,
      owns: State.generations_of(state, peer),
      quarantined: quarantined,
      halted: Map.get(state.halted, peer),
      last_error: replicator.last_error,
      last_success: replicator.last_success
    }
  end

  @doc """
  Compares this node's streams with `peer`'s, over Erlang distribution.

  For every stream name, both nodes' histories (archived incarnations, then
  the live stream) are compared by content: event ids, types, data, metadata
  and timestamps.

    * `:prefix` (default) works while both nodes write: one node's history of a
      stream must be a prefix of the other's. Returns `:ok`, or
      `{:lag, [{stream, :local_behind | :remote_behind}]}`.
    * `:strict` requires identical histories; use it once replication is idle.

  Returns `{:error, differences}` when the histories fork, or in `:strict`
  mode when they differ at all, and `{:error, :not_connected}` when the peer
  can't be reached.
  """
  def verify(peer, mode \\ :prefix) when mode in [:prefix, :strict] do
    case :pg.get_members(Write.pg_scope(), {:node, peer}) do
      [pid] -> verify_with(node(pid), mode)
      _ -> {:error, :not_connected}
    end
  end

  defp verify_with(peer_node, mode) do
    alias EventstoreSqlite.Sync.Verify

    remote = :erpc.call(peer_node, Verify, :summaries, [], 120_000)
    local = Verify.summaries()

    prefix_digest = fn
      :local, stream, first_id, count -> Verify.prefix_digest(stream, first_id, count)
      :remote, stream, first_id, count -> :erpc.call(peer_node, Verify, :prefix_digest, [stream, first_id, count])
    end

    case Verify.compare(local, remote, mode, prefix_digest) do
      {:ok, []} -> :ok
      {:ok, lag} -> {:lag, lag}
      error -> error
    end
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
  defdelegate export(request), to: Export

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
    if state.enabled, do: Write.poke(state.node_id)
    EventstoreSqlite.Changes.notify([:streams, :sync])
    Server.refresh()
  end
end
