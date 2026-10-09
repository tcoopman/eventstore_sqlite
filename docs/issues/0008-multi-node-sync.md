# Issue — sync two stores, with exactly one writer per stream

- **Status:** Design. Nothing built yet. The implementation plan is [0008-multi-node-sync-plan](0008-multi-node-sync-plan.md). Where they differ, the plan wins: disjoint assignments, ownership generations, `revoke_node` as the forced reclaim, and a reconciliation tick in `Subscriptions`.
- **Found via:** running a temporary second server next to main-node for a
  few days, then handing everything back to main-node.

## Decisions so far

| Question | Decision |
| --- | --- |
| Topology | Peers. Both nodes write, each only to the streams it owns, and both end up with every event. |
| Connectivity | A cluster connected over Erlang distribution that is mostly up. After a short drop, a node catches up. |
| Ownership source | An explicit API on the store, for exact stream names and prefix patterns (`"foo:*"`). Every change is recorded as a system event. |
| Who changes ownership | Only the home node (main-node). The other node can only release what it owns back to home. |
| Handover | Explicit, never automatic. Home can force a reclaim while the other node is unreachable (nice to have). |
| Forced reclaim, then the old owner comes back | Home rejects that node's events written after the reclaim and quarantines them. The old owner is marked diverged and has to be rebuilt from a new snapshot. |
| Sync log | Written only while sync is enabled. The enabled flag is stored in the database. Entries are deleted once every peer has them. |
| Which events sync | All of them. Every stream is replicated to every node. |
| Where sync state lives | System events, like `StreamArchived`. Enabling or disabling sync, the node id and peers go in `"$sync"`, and ownership changes go in `"$ownership"`. Tables such as `stream_owners` are rebuilt from those events and only exist so writes can check them quickly. The outgoing change log stays a table, because its entries are deleted and stored events can't be. |
| Subscriptions | Local only. A subscriber resumes from its own checkpoint. Silent ends are tracked in 0009. |
| Patterns | A trailing `*` prefix for now (`"venue-a:*"`). To be discussed further. |
| Bootstrap | Copy main-node's database, then catch up from there. |
| Append to a stream the node doesn't own | `{:error, :not_owner}`. No forwarding. |
| Durability | Asynchronous. An append commits locally and is shipped in the background. |
| Archives | Only the owner archives. The archive is replicated, and the peer archives the same stream at the same version. |
| Transport | Erlang distribution. |
| `$all` order | Open; see below. Recommendation: each node keeps its own order. |

## Why `$all` can't have the same positions everywhere

`$all` positions are assigned by whoever inserts the row. With two writers and
asynchronous shipping, the event main-node writes at 10:00:01 and the event the secondary-node
writes at 10:00:02 reach each other's node after that node's own event, so the
two orders differ. The only way to get identical positions is a single sequencer
(main-node) handing out positions, which means the secondary-node can't append while main-node is
unreachable. That contradicts the async decision.

**Recommendation: `$all` is a per-node log in local arrival order.** What still
holds:

- Every stream has the same versions on every node, because a stream has one
  writer.
- On each node, `$all` keeps each origin's order, and an event never comes
  before an event that existed on its origin node when it was written, so causal
  order is preserved. If the secondary-node writes E2 after reading main-node's E1, the secondary-node had
  E1 first, and main-node wrote E1 first.
- A `$all` checkpoint is only valid on the node that produced it. Because the
  secondary-node starts from a copy of main-node's database, its `$all` is identical to main-node's
  up to the copy point. A projection whose state and checkpoint were copied
  along with it stays valid on the secondary-node.

The sync feed therefore can't be `$all`: positions are local, and
`Migration.intial_fill_all/0` renumbers them. Sync needs its own log.

## Design

### 0. Subscriptions

Local only, and the subscriber keeps its own checkpoint. Imported events reach
local subscribers through the normal ping (section 3). The problem of
subscriptions ending without the subscriber being told is a separate issue:
[0009](0009-subscriptions-end-silently.md).

### 1. Node identity

The latest `SyncEnabled` event in `"$sync"` holds this store's `node_id`, a stable string
and not the Erlang node name. Config names the node
(`config :eventstore_sqlite, node_id: "main-node", home: "main-node", peers: [...]`).

At boot, the store refuses to start if the configured `node_id` differs from the
one in the database. That catches the bootstrap mistake: a copy of main-node's
database started as the secondary-node would otherwise write events under main-node's identity.
`Sync.snapshot/1` (below) marks a copy as unclaimed, so the first boot of the
secondary-node takes the configured id.

### 2. The sync log, which records what changed

This covers the first gap: an append records nothing about what to send.

```
sync_log(seq INTEGER PRIMARY KEY AUTOINCREMENT,   -- local order
         origin TEXT NOT NULL,                    -- node_id that made the change
         origin_seq INTEGER NOT NULL,             -- seq on the origin node
         kind TEXT NOT NULL,                      -- append | archive | ownership
         stream_id TEXT,
         stream_version INTEGER,                  -- append: first version; archive: event count
         payload BLOB,                            -- ownership record
         UNIQUE (origin, origin_seq))
sync_log_events(log_seq, position, event_id)      -- the batch's events, in order
```

- Every local append, archive and ownership change writes one entry in the same
  transaction, with `origin = self` and `origin_seq = seq`. An append batch
  stays one entry, so it is imported atomically too.
- The event IDs are stored explicitly rather than derived from
  `(stream_id, version range)`. A peer that is behind may ask for an append
  whose stream has since been archived. The `events` rows survive an archive
  (`no_delete_events`), so the entry can still be served.
- The log only holds entries this node made. An imported entry isn't logged
  again. Instead, the import advances `sync_cursors(origin, origin_seq)` in the
  same transaction, so each entry is applied exactly once, and a re-sent entry
  at or below the cursor is skipped. A database copy carries the cursors along.

**The log is written only while sync is enabled.** With nothing configured,
it stays empty, and a single-node store behaves exactly as today. Enabling sync
is a `SyncEnabled` system event in `"$sync"`, not only config. Otherwise, deploying main-node
without the sync config while the secondary-node is still running would stop logging, and
the secondary-node would never get those events. Once enabled, sync stays on until it is
explicitly disabled, and disabling is refused while a peer's cursor is behind
the log head.

**An entry is deleted once every peer's cursor is past it.** A new peer gets
older history from the database copy, so nothing older is needed. After the secondary-node
is handed back, removed and sync is disabled, the log is empty again.

Events written before sync was enabled have no entries. They only reach a peer
through the database copy, which is the chosen bootstrap anyway.

### 3. Import without changing events

This covers the second gap: importing a peer's events as they are. Add an
internal `import_entry` next to `append_to_stream`, sharing `insert_in_stream`:

- Insert the `events` rows with their original `id`, `type`, `data`, `metadata`
  and `inserted_at`, as raw binaries. It doesn't decode, re-encode or run
  upcasters, so a node doesn't even need the event modules loaded to relay them.
- Append the stream rows only if the local `stream_version` equals the entry's
  first version. Anything else means the single-writer rule was broken. Stop
  that peer's replication and report the error; never skip the entry.
- Add `$all` rows at local positions, as a normal append does.
- Write the `sync_log` entry, which advances the cursor in the same transaction.
- After commit, call `Subscriptions.ping(stream_id)`, exactly as an append does.
  Subscribers then see imported events with no other change, because
  `Subscriptions` reads rows by version. This fixes "subscribers only fire on
  local appends".
- An archive entry runs the existing `archive_in_transaction` with
  `expected_version: {:version, n}`, through `Subscriptions.archive_stream/2` as a
  local archive does. Each node then gets its own `StreamArchived` in its own
  `$archives`, with a local `archive_id`.

This also covers the third gap from the replication side: archiving becomes an
entry in the log, so the feed no longer misses it.

### 4. Ownership

State is kept in a table, `stream_owners(selector, kind: exact | prefix, owner,
since_seq)`, so the check can run inside the write transaction. Every change
also appends a system event to a new reserved stream, `"$ownership"`:
`OwnershipAssigned`, `OwnershipReleased` or `OwnershipRevoked`. Like `$all`,
`"$ownership"` is written by the store itself on each node, so it isn't a stream
with two writers.

To find a stream's owner, an exact name wins, then the longest matching prefix
pattern. Otherwise the home node owns it. Without sync config, home is the node
itself, so single-node behaviour doesn't change. System streams have no owner.

The check goes into `append_to_stream/3` and `archive_stream/2` inside the
`:immediate` transaction and returns `{:error, :not_owner}`. It has to be inside
the transaction. Otherwise an ownership change could commit between the check
and the write (`RepoWrite` has `pool_size: 1`, so the transaction serialises
them).

API, all under a new `EventstoreSqlite.Ownership` module:

- `assign(selector, node_id)`: home only. main-node rejects matching appends as soon
  as this commits. The secondary-node may only write once it has imported the entry. The
  secondary-node imports main-node's log in order, so by then it already has every event main-node
  wrote to those streams. This ordering is what makes the handover safe, and it
  is why the importer must apply entries strictly in `origin_seq` order.
- `release(selector)`: on the current owner, for a planned handover. One
  transaction fences the streams locally and logs `OwnershipReleased`. Once
  home imports that entry, it has every event the secondary-node wrote before the release,
  and ownership returns to home.
- `reclaim(selector)`: on home. While the secondary-node is reachable, it asks the secondary-node to
  `release` over distribution and waits until the entry has been imported. This
  is the normal handover.
- `reclaim(selector, force: true)`: on home, while the secondary-node is unreachable. It
  logs `OwnershipRevoked{from: node, cutoff: last imported origin_seq of that node}`.
  secondary-node entries after the cutoff that touch a revoked stream go to a
  `sync_quarantine` table instead of being applied. secondary-node entries for streams the
  secondary-node still owns import normally.
- `owner(stream_id)` and `list()`.

### 5. Replication process

Replication pulls; it doesn't subscribe remotely. This covers the third gap:
remote subscriptions are dropped silently when the link breaks.

- Each node runs a `Sync.Replicator` per peer, under the application
  supervisor. It calls `:erpc.call(peer, EventstoreSqlite.Sync, :export, [origin,
  after_seq, limit])` and imports the entries it gets back.
- The cursor lives in the importing database (see section 2), so a dropped
  link, a crash or a restart only delays replication and never loses data. On
  errors it retries with backoff. It follows `:nodeup`/`:nodedown` to reconnect.
- For low latency, an append on the origin sends the peer's replicator a "poke"
  (via `:pg`), and the replicator pulls. Pokes may be lost; the pull is the
  source of truth, with a periodic pull as a fallback.
- Each node pulls only entries whose origin is the peer. With two nodes there
  is nothing to relay.
- `Sync.status()` returns, per peer, whether it is connected, the local cursor,
  the peer's head, the lag, and whether replication is halted. An operator
  checks this before a handover.

The remote-subscription gap itself (the subscriber is never told that its
registration died with `:noconnection`) is separate. Sync no longer depends on
it. It can be fixed by documenting that subscribers should monitor
`EventstoreSqlite.Subscriptions`, or by returning a reference to monitor.

### 6. Bootstrap from a database copy

- `Sync.snapshot(path)` on main-node: run `VACUUM INTO path` for a consistent copy
  even while WAL is active (a plain `cp` of a live WAL database isn't safe), and
  mark the copy as unclaimed.
- Start the secondary-node on the copy with `node_id: "secondary-node-1"`. It claims the identity, its
  cursor for main-node is already right, and its replicator pulls the rest.
- Each secondary-node session gets a new `node_id` (for example `"secondary-node-2026-10"`). Reusing
  an id would also mean continuing its `origin_seq` above main-node's cursor for it.
  Fresh IDs avoid that and keep the quarantine and the logs unambiguous.

## What has to be built

1. Migration for `sync_log`, `sync_log_events`,
   `sync_cursors`, `stream_owners` and `sync_quarantine`, and reservation of `"$ownership"`.
   Existing data needs no backfill.
2. Writing the log entry in `append_to_stream/3` and `archive_in_transaction/3`
   while sync is enabled, enabling and disabling sync, and pruning entries every
   peer has fetched.
3. `import_entry` (append and archive), sharing `insert_in_stream/3`, and the
   subscription ping after import.
4. Ownership resolution and the `:not_owner` check in append and archive, plus
   the `Ownership` API and system events.
5. `Sync.export/3`, `Sync.Replicator`, the poke via `:pg`, and `Sync.status/0`.
6. Identity check at boot and `Sync.snapshot/1`.
7. Forced reclaim and quarantine on home. When the old owner imports the
   `OwnershipRevoked`, it marks itself diverged, stops replicating and refuses
   writes. It has to be rebuilt from a new snapshot.
8. Tests across two BEAMs. `RepoWrite`, `RepoRead` and `Subscriptions` are
   globally named singletons, so one BEAM can hold only one store. Tests need
   `:peer` nodes (OTP 28 is available), each with its own database file. Cover:
   handover during concurrent appends, a dropped link mid-batch, archive after
   handover, forced reclaim with quarantine, and replaying an entry twice.
9. A CHANGELOG entry. `append_to_stream/3` and `archive_stream/2` gain
   `{:error, :not_owner}`, and `"$ownership"` and `"$sync"` become reserved, so the
   migration must refuse to run on a store that already has a stream with
   either name, as `"$archives"` did.

Suggested order: 1–3 first (a secondary-node that mirrors main-node read-only, with no
ownership yet, testable on its own), then 4, then 5–6, and 7 last.

## Open questions

1. Patterns beyond a trailing `*`.
2. Consumers such as tickets-admin will have to handle `{:error, :not_owner}`,
   and give each node its own projection checkpoints. These changes belong in tickets-admin and
   aren't part of this work.
