# Plan — multi-node sync with one writer per stream

- **Status:** Plan, revision 7. Approved by both outside reviewers; see [the review log](0008-multi-node-sync-review.md). Design and decisions:
  [0008](0008-multi-node-sync.md). Related: [0009](0009-subscriptions-end-silently.md).
- **Goal:** two instances of an app, each with its own eventstore_sqlite
  database, both holding every event. Each stream has exactly one node that may
  write to it. A secondary-node runs for days next to "main-node" and is then handed
  back.

## Context: the store today

- SQLite through two Ecto repos on one file: `RepoWrite` (`pool_size: 1`, so
  every write is serialised) and `RepoRead`. WAL mode, foreign keys on (the
  `ecto_sqlite3` default).
- Tables:
  - `events(id uuid PK, type, data blob, metadata blob, inserted_at)` stores
    `:erlang.term_to_binary` blobs. It can't be updated or deleted (triggers).
  - `streams(stream_id unique, stream_version)` holds the next version, which is
    also the count.
  - `stream_events(id autoincrement, event_id, stream_id, stream_version,
    original_stream_id, original_stream_version)` can't be updated. Each event
    has one row in its stream and one in `"$all"`.
  - `archived_streams` and `archived_stream_events` hold archived streams.
- `append_to_stream(stream, events, expected_version)` runs one `:immediate`
  transaction: check the version, insert `events`, insert the stream rows,
  insert the `"$all"` rows at the next `"$all"` positions. After commit it
  calls `Subscriptions.ping(stream)`, a cast.
- `archive_stream(stream, expected_version)` runs its transaction inside the
  `Subscriptions` GenServer. It moves the stream's rows to the archive tables,
  deletes them from the stream and `"$all"`, and appends `StreamArchived` to
  `"$archives"`, which is not in `"$all"`. Subscribers to the stream get
  `{:stream_archived, s}` and are unsubscribed. A stream name can be reused
  after an archive.
- `Subscriptions` is one local GenServer that pushes events to registered pids
  by stream version.

## Decisions (from the discussion with the owner)

1. Two peers. Both write, each only to streams it owns, and both hold every
   event. Every stream is replicated.
2. Erlang distribution, mostly connected. Short drops are followed by catch-up.
3. Ownership is set through an explicit API, by exact stream name or trailing
   `*` prefix. Only the home node (main-node) assigns. The owner may release back to
   home. Home may reclaim, and it may force a reclaim while the owner is
   unreachable (`revoke_node`).
4. After a forced reclaim, the old owner's events for the reclaimed streams that
   home hasn't imported yet are quarantined on home. The old owner becomes
   diverged and is rebuilt from a new snapshot.
5. Bootstrap is a copy of main-node's database, then catch-up.
6. Appending to a stream the node doesn't own returns `{:error, :not_owner}`.
   There is no forwarding.
7. Replication is asynchronous. An append commits locally, and shipping happens
   in the background.
8. Only the owner archives. The archive is replicated, and the peer archives at
   the same version.
9. `$all` is per node, in local arrival order. Stream versions are identical on
   every node, but `$all` positions are not. Projection checkpoints are per
   node.
10. Sync state lives in the store as system events: `"$sync"` for identity,
    enablement and peers, `"$ownership"` for ownership changes. Tables derived
    from them exist for fast checks.
11. The change log is written only while sync is enabled, and it is empty
    otherwise. Entries are pruned once every peer has them.
12. Subscriptions are local only. Silent subscription loss is fixed separately
    in 0009.

## Assumptions (made while the owner was away; to confirm)

- A1. Exactly two nodes are tested and supported. Nothing relays entries; a node
  only pulls entries a peer originated itself.
- A2. **Versions.**
  - *Required:* both nodes run an eventstore_sqlite version with the same
    sync protocol version and the same migrations. The library bumps the
    protocol version whenever the export/import format changes. A mismatch
    halts replication with a clear error, and the copied database must have
    the migrations the secondary-node expects.
  - *Not required:* the same app release. Import copies event payloads as
    raw binaries, so it never needs the event modules.
  - *Recommended:* deploy the app to both nodes together. A node running
    older app code still stores a newer node's events. Its own code
    (projections, LiveViews, upcasters) may fail when it reads an event type
    or field it doesn't know yet.
- A3. Each secondary-node session gets a new `node_id` (for example `"secondary-node-2026-10"`). An
  id is never reused. A forced reclaim is node-level: it revokes every active
  generation of that node and retires its id for good, since the node becomes
  diverged anyway. A new secondary-node gets a new id, and the old peer is removed before
  the next one is provisioned.
- A4. The Erlang node name of each peer is deployment configuration
  (`peers: %{"secondary-node-1" => :"app@secondary-host"}`). Its `node_id` lives in `"$sync"`.
  Distribution security is the app's responsibility.
- A5. The app connects the nodes, for example with libcluster. The replicator
  uses `:erpc` and reacts to `:nodeup`/`:nodedown`.
- A6. 0009 ships before sync goes to production, but is not part of this plan.
  Sync works without it. With sync, every node's projections and LiveViews
  depend on `Subscriptions` for events written elsewhere. A single crash there
  (for example an upcaster raising on an event written by the other node's
  newer code, see A2) silently stops all of them until restart, and the
  reconciliation tick can't help, because the registrations themselves are
  gone.
- A7. A halted replication does not stop local writes to streams this node owns
  (see "Halted versus diverged"). A diverged node refuses all writes and
  serves stale reads. A node only learns it is diverged when it imports main-node's
  `NodeRevoked` after reconnecting. Until then it keeps writing, and those
  writes are quarantined; that is the forced-reclaim window. How divergence is
  surfaced is described in "Detecting divergence".
- A8. Timestamps are preserved on import. Clock skew only affects `created_at`.
- A9. No automatic failover.
- A10. **Ownership assignments may not overlap.** An assignment's selector must
  not overlap any other active assignment. Two selectors overlap when they're
  equal, when an exact name matches a prefix, or when one prefix starts with the
  other. Nested exceptions such as "`venue:*` on the secondary-node except `venue:vip`" are
  not supported in this version. Streams that match no assignment belong to
  home. This keeps every handover a disjoint region with one previous owner.

## Invariants

- **I1 — one writer.** For every stream, at most one node accepts a write at a
  time, with one exception by design: after a forced reclaim during a
  partition, the old owner may keep accepting writes until it learns of the
  reclaim. Its entries up to the durable `cutoff` (home's cursor at revoke
  time) were already imported and stay. Every entry after the cutoff carrying a
  revoked generation is quarantined and never reaches the replicated history.
- **I2 — identical streams.** Once replication is quiet and no forced reclaim
  happened, both nodes hold the same rows for every live stream:
  `(version, event id, type, data, metadata, inserted_at)`. They also hold the
  same archived stream incarnations.
- **I3 — no lost acknowledged write.** An append that returned `:ok` reaches
  every active, non-retired peer eventually. A retired secondary-node stops importing at
  the revoke, so home's later writes never reach it; its replacement gets them
  through its snapshot and catch-up. The exception is writes the old owner made under a
  generation that was force-revoked and that home hadn't imported at the time of
  the reclaim. Those are quarantined on home and kept there. The second
  exception is `remove_peer(..., discard_unpulled: true)` for a secondary-node that is
  gone for good: whatever it wrote after home's last pull is lost, and the
  call logs that.
- **I4 — per-origin order.** A node applies a peer's entries strictly in that
  peer's `seq` order, contiguously, each exactly once. An entry's effects and
  the cursor advance commit in one transaction.
- **I5 — handover safety.** For an assignment or a planned reclaim, a node
  writes a stream under its new ownership only after it holds every event the
  previous owner wrote to that stream. A forced reclaim (`revoke_node`) breaks
  this on purpose, and the events it skips are exactly the quarantined ones.
- **I6 — stale ownership operations are harmless.** A release or reclaim that
  names an assignment generation that is no longer current changes nothing.

## Ownership generations

Every assignment has a **generation**: the home node's `sync_log.seq` of the
entry that created it. It is unique and increasing, and only home issues
generations.

- `stream_owners(selector, kind, owner, generation)` lists the active
  assignments that aren't home. They are disjoint (A10).
- The effective owner of a stream is the matching assignment, which is exactly
  one or none. With none, it is home under generation 0.
- **Every append and archive entry records the generation that authorized it.**
  That generation is resolved in the write transaction.
- A release names the generation it releases. Home applies it only if that
  generation is still active for that owner, and ignores it otherwise (I6).
- A forced reclaim moves generation G to `sync_revoked(generation, from_node,
  cutoff)`. `cutoff` is home's import cursor for `from_node` at reclaim time.
  Every entry from `from_node` that carries G and arrives after that point is
  quarantined. This covers writes the old owner acknowledged before the reclaim
  but home hadn't imported yet; they are lost from the replicated history, by
  design (decision 4).

### Import authorization

The importer checks every entry against its own replayed state, which equals
the origin's state at that point in the origin's log (I4). The exception is the
importer's own releases and revokes, which it applied before the origin saw
them; the rules below cover those.

**Append or archive entry from origin O for stream S, carrying generation G:**

- G > 0, G active, owned by O, and S matches G's selector: apply it.
- G = 0, O is home, and S matches no active assignment: apply it. Home could
  only have written S under G = 0 after importing the secondary-node's release of that
  region. The secondary-node removed the region locally when it released, so the secondary-node's
  state agrees.
- G is in `sync_revoked` with `from_node = O`, and S matches its selector:
  quarantine it.
- Anything else, such as an unknown generation, S outside the selector, a
  generation owned by another node, or G = 0 from a non-home node: halt with
  `:ownership_violation`.

**Ownership entry from origin O:**

- `OwnershipAssigned` / `NodeRevoked`: O must be home, otherwise halt. These
  carry their own new generation and need no authorizing generation.
- `NodeRevoked` naming the importer's own node id makes the importer diverged
  unconditionally, whether or not it still holds any of the listed
  generations. A secondary-node may have released its last region locally while
  partitioned and still be revoked, and it must be fenced all the same.
- `OwnershipReleased{G}`:
  - G active and owned by O: apply it.
  - G revoked from O, or already released: write `ReleaseIgnored` (I6).
  - G active but owned by another node, or G unknown: halt.

Planned handover needs no special case. The secondary-node fences itself when it releases,
so every entry carrying G comes before the release in the secondary-node's log, and home
imports in order. All of them arrive while G is still active.

## Schema (one migration)

```
sync_log(seq INTEGER PRIMARY KEY AUTOINCREMENT,
         kind TEXT NOT NULL,              -- 'append' | 'archive' | 'ownership'
         stream_id TEXT,
         stream_version INTEGER,          -- append: first version; archive: event count
         generation INTEGER,              -- append/archive: authorizing generation
         payload BLOB,                    -- ownership: term_to_binary of the record
         inserted_at TEXT NOT NULL)
sync_log_events(seq INTEGER NOT NULL, position INTEGER NOT NULL, event_id BLOB NOT NULL,
                PRIMARY KEY (seq, position))
sync_cursors(origin TEXT PRIMARY KEY, seq INTEGER NOT NULL)        -- imported from origin
sync_acks(peer TEXT PRIMARY KEY, seq INTEGER NOT NULL)             -- peer confirmed from me
stream_owners(selector TEXT NOT NULL, kind TEXT NOT NULL, owner TEXT NOT NULL,
              generation INTEGER NOT NULL, PRIMARY KEY (selector, kind))
sync_revoked(generation INTEGER PRIMARY KEY, selector TEXT, kind TEXT,
             from_node TEXT NOT NULL, cutoff INTEGER NOT NULL)
sync_quarantine(id INTEGER PRIMARY KEY AUTOINCREMENT, origin TEXT, seq INTEGER,
                entry BLOB, reason TEXT, inserted_at TEXT)
sync_state(key TEXT PRIMARY KEY, value BLOB)  -- node_id, home, enabled, peers, diverged, halted
```

- `sync_log` holds only entries this node made, so `seq` is its origin
  sequence. AUTOINCREMENT never reuses a seq. A rolled-back transaction also
  rolls back `sqlite_sequence`, so a node's seqs are contiguous. The head is
  `sqlite_sequence` for `sync_log`, which stays correct even when the table has
  been pruned empty.
- Pruning deletes `sync_log_events` and `sync_log` rows explicitly, rather than
  relying on a cascade.
- Every derived table (`stream_owners`, `sync_revoked`, `sync_state`) is
  rebuilt by `Sync.rebuild_state/0`, which replays `"$sync"` and `"$ownership"`
  in a write transaction.
- `sync_retired(node_id, revoked_at_seq)` lists retired node ids. It is
  derived and replayed from `NodeRetired` in `"$ownership"`.
- `sync_released(generation PRIMARY KEY, owner, release_seq)` records every
  completed release with the owner's original seq. It is derived and replayed
  from `OwnershipReleased{generation, from, release_seq}`, and it survives
  pruning, so a retried `release`/`reclaim` gets the same answer after
  restarts.
- **No in-memory cache.** The write path reads `sync_state` and
  `stream_owners` inside its own `:immediate` transaction. All changes to them
  also go through `RepoWrite`, so the single connection serializes them and a
  write can't see stale state. With sync disabled, the cost is one primary-key
  lookup per append. Phase 1 benchmarks this against today.
- The migration reserves `"$sync"` and `"$ownership"`, failing if either already
  exists. Neither is in `"$all"`; both join `system_streams/0`.

## System events

In `EventstoreSqlite.SystemEvents`, with fields only ever added:

- `"$sync"`:
  - `SyncEnabled{node_id, home, sync_id}`. `sync_id` is a random UUID naming
    this replication group.
  - `PeerAdded{node_id, pinned_seq}`
  - `PeerRemoved{node_id}`
  - `SnapshotCreated{snapshot_id, for_node, snapshot_of, head_seq}`. This one is
    written only into the copy.
  - `SnapshotClaimed{snapshot_id, node_id, snapshot_of, cursor}`
  - `SyncHalted{peer, reason}`, `SyncResumed{peer}`
  - `NodeDiverged{node_id, revoked_by, revoke_seq}`: this node's id, the home
    node that retired it, and the origin seq of the `NodeRevoked` entry. This
    also works when the node held no generation at the time.
  - `SyncDisabled{}`
- `"$ownership"`:
  - `OwnershipAssigned{selector, kind, to, generation}`
  - `OwnershipReleased{generation, from, release_seq}` and
    `ReleaseIgnored{generation, from}`, the latter for a stale release.
  - `OwnershipRevoked{generation, from, cutoff}`, one per generation revoked
    by a forced reclaim.
  - `NodeRetired{node_id}`

The store itself writes both streams on each node: for the node's own changes,
and when it applies a peer's ownership entry. `rebuild_state/0` replays them to
produce exactly the derived tables. The replay rules are written as one pure
function, which the property tests target.

## Write path (`append_to_stream/3`, `archive_stream/2`)

Inside the existing `:immediate` transaction:

1. Read `sync_state`. If this node is diverged, return `{:error, :diverged}`.
   This check comes first, and nothing can clear it (see "Administration
   guards").
2. If sync is disabled, continue exactly as today.
3. Resolve the owner and generation. If the owner isn't this node, return
   `{:error, :not_owner}`.
4. Do the existing work.
5. Insert the `sync_log` row with its generation, and the `sync_log_events`
   rows.
6. After commit, call `Subscriptions.ping` and poke the replicators on the
   peers.

Internal functions used by import (`insert_imported_append/…` and the archive
variant below) skip steps 1–3 and 5. They are not public.

## Export (`Sync.export/2`, called over `:erpc`)

The request is `%{protocol: 1, sync_id, from: node_id, expect: origin_node_id,
after_seq, max_entries, max_bytes}`.

1. Validation. Halt the peer with a clear error when:
   - the protocol differs;
   - the `sync_id` differs (another replication group, or a stale database);
   - `expect` isn't this node's id (wrong node behind that address);
   - `from` isn't a current peer.
2. Reading. In one read transaction on `RepoRead`, which gives a consistent WAL
   snapshot: read the head from `sqlite_sequence`, the oldest kept seq, and the
   entries with `seq > after_seq` (at least one entry and at most the limits,
   never splitting an entry), plus their events by id. Events are never
   deleted, so entries for streams that were archived since are complete.
3. Outcomes:
   - `after_seq > head` is rejected as `:ahead_of_origin`, meaning a wrong or
     rolled-back database. The requester halts.
   - `after_seq == head` returns `{:ok, [], head}`, which means idle.
   - `after_seq < head` but `after_seq + 1` is not in `sync_log`, either
     because it was pruned or because the table is empty after pruning:
     `{:error, :pruned}`. The requester halts, because that peer needs a new
     snapshot.
   - Diverged or halted state on the exporting node doesn't stop exporting. A
     diverged secondary-node must still serve its late entries so home can quarantine
     them.
   - The response carries the exporter's `head` and `diverged` flag, read in
     the same read transaction as the entries. A drain check can therefore
     never pair a head from before the divergence with the state after it.
4. Acks. The request is also the ack: the requester has applied everything up
   to `after_seq`. In a separate write transaction, set
   `sync_acks[from] = max(old, after_seq)` (it is already `≤ head` from step 3),
   after checking again that `from` is still a current peer, since a removal
   can commit between the read and this write. Then prune `seq ≤ min(sync_acks)` over the current peers. A current peer with
   no ack row prevents all pruning.

## Import (`Sync.Import`, internal, run by the replicator)

Entries are applied in order. Consecutive append and ownership entries are
grouped into one `:immediate` transaction, up to about 1000 events; the bound
only falls between entries. An entry larger than the bound gets a transaction
to itself and is never split. Each archive entry is applied on its own (see
below). Per entry:

1. If `seq ≤ cursor(origin)`, skip it as a duplicate. If
   `seq > cursor(origin) + 1`, halt with `:gap`.
2. Authorization, as described in "Ownership generations": apply, quarantine
   (store the entry, advance the cursor) or halt.
3. Append: the local version (0 when the stream doesn't exist) must equal
   `stream_version`, otherwise halt with `:version_conflict`. Insert the
   `events` with their original id, type, data, metadata and `inserted_at`, as
   raw binaries. Then insert the stream rows and the `"$all"` rows at local
   positions. Nothing is logged.
4. Ownership entry: apply the replay function to the derived tables and append
   the matching `"$ownership"` events, all in the same transaction as the
   cursor. Nothing is logged.
   - A `NodeRevoked` entry is one compound entry: the node id, the list of
     revoked `{generation, selector, kind}`, and the cutoff. Its import writes
     every `OwnershipRevoked` event and the `NodeRetired` event, updates
     `sync_revoked` and `sync_retired`, and (on the revoked node) writes
     `NodeDiverged`, together with the cursor in one transaction. A crash
     anywhere leaves either none of it or all of it.
   - A `NodeRevoked` naming this node is always the last entry its
     transaction processes. Later entries in the same batch are not applied,
     the transaction commits with the cursor at the revoke, and the
     replicator stops.
   - A release of an inactive generation writes `ReleaseIgnored`.
5. Set `sync_cursors[origin] = seq` in the same transaction.
6. After commit, ping `Subscriptions` for every touched stream, plus `"$all"`
   and `"$ownership"`.

**Lost pings.** A process that dies between commit and ping (the replicator
here, or the caller of `append_to_stream` today) leaves an idle stream's
subscribers without a notification, and a replay skips the entry. Two fixes:

- `Subscriptions` gets a reconciliation tick, every second by default. In one
  query it compares `streams.stream_version` for the subscribed streams with
  its read cursors and enqueues any stream that is ahead.
- The replicator calls `Subscriptions.ping_all/0` when it starts.

The tick also fixes the same gap for local appends. A test commits, kills the
replicator before the ping, writes nothing more, and expects delivery.

**Committed but not yet cleaned up.** Both `apply_archive` and the existing
local archive split the work. The transaction is wrapped in a `catch` that
turns a failure into a returned error, because nothing was committed. The
in-memory cleanup after commit (ending subscriptions, pings) is outside that
`catch`. An exception there crashes `Subscriptions` on purpose. Its restart
drops every registration, and subscribers recover through 0009. It never
continues with stale cursors attached to a stream that may be reused. A test
raises at the post-commit failpoint (a raise, not a kill), then checks that
`Subscriptions` restarted and no old registration survives a reuse of the
name.

**Archive entries.** The replicator calls a new
`Subscriptions.apply_archive(stream, fun)`. The GenServer runs `fun`, which
opens one `RepoWrite` transaction. Inside it:

- check the cursor and the authorization (steps 1–2);
- run the existing `archive_in_transaction(repo, stream, {:version, n})`
  without the ownership check and without logging;
- set the cursor.

The function returns `{:applied | :duplicate | :quarantined, ...}`. Only
`:applied` ends the stream's local subscriptions and pings `"$archives"`. That
cleanup is in-memory work in the GenServer right after commit, like a local
archive today. If the GenServer itself crashes there, every registration is
lost and 0009 applies. Tests cover each outcome with active subscribers and with
the name reused afterwards. A returned error (`:stream_not_found`, `:wrong_expected_version`)
halts with `:archive_conflict`. No `RepoWrite` transaction is ever open while
calling the `Subscriptions` GenServer; the call happens first, and the
transaction opens inside it.

## Halted versus diverged

- **Halted** (a gap, a version conflict, an ownership violation, a pruned
  range, a protocol, `sync_id` or identity mismatch): replication from that
  peer stops. Local writes to streams this node owns continue. That is safe:
  only home grants ownership, and a missed home entry can only be an
  assignment the node doesn't use yet or a forced revoke, which is the case
  accepted by decision 4. Home missing secondary-node entries only means home still
  considers the secondary-node the owner, so it refuses those writes, which is safe.
  `Sync.resume(peer)` retries after a manual fix. It clears a halt, never
  divergence.
- **Diverged** (this node imported a `NodeRevoked` naming its own id, whether
  or not it still held any generation): every
  append, archive and ownership operation returns `{:error, :diverged}`.
  Replication stops. Reads still work. The only way out is a new snapshot
  under a new node id.

## Replication (`Sync.Replicator`)

One GenServer per peer under `Sync.Supervisor`, started when sync is enabled
and the peer has a configured Erlang node name.

- It loops `:erpc.call(peer_node, Sync, :export, [request], 15_000)`, then
  imports, and repeats immediately while batches are full.
- On an error or `:nodedown`, it backs off from 100 ms to 5 s. The cursor is in
  the database, so nothing is lost.
- When idle, it waits for a poke (`:pg` group `{:eventstore_sqlite_sync,
  origin}`) or a 1 s timer. Pokes are hints only.
- `Sync.status/0` reports, per peer: state (`:connected | :disconnected |
  :halted | :diverged | :retired | :drained`), cursor, the peer's head from the last export, lag,
  last error, last success time, quarantine count, and the peer's ack of our
  log (which shows whether it is pruning-blocking and since when).
- Telemetry: `[:eventstore_sqlite, :sync, :import | :halt | :lag | :quarantine]`.

## Ownership API (`EventstoreSqlite.Ownership`)

All of these return `{:error, :sync_disabled}` when sync is off, and
`{:error, :diverged}` on a diverged node.

- **`assign(selector, to_node)`**, on home only. It returns
  `{:ok, generation}`. `to_node` must be a current
  peer that isn't retired, and the selector must not overlap an active
  assignment (`{:error, :overlap}`). In one transaction it:
  - inserts the `stream_owners` row with generation = this entry's seq;
  - appends `OwnershipAssigned`;
  - logs the entry.

  Home refuses matching writes from that commit on. The peer may write once it
  has imported the entry, and by then it has every earlier home event (I5).
- **`release(generation)`**, on the owner, also callable over `:erpc`. If the
  generation is in `sync_released`, it returns `{:ok, release_seq}` from
  there, which makes retries idempotent across restarts and pruning. If the
  generation is active and owned here, then in one transaction it:
  - deletes the local row (a fence: local writes now resolve to home, so they
    get `:not_owner`);
  - appends `OwnershipReleased`;
  - logs the entry;
  - returns `{:ok, release_seq}`.

  Otherwise it returns `{:error, :not_active}`.
- **`reclaim(generation, opts)`**, on home. It takes the generation, not the
  selector, so a retry can never touch a later assignment. Get the generation
  from `assign`, `owner/1` or `list/0`.
  - If G is in home's `sync_released`, meaning the release was already
    imported, it returns `:ok` at once.
  - If G is revoked, it returns `{:error, :revoked}`.
  - If G is active, it calls `release(G)` on the owner over `:erpc` and waits
    until home's import has put G into `sync_released` (default timeout 30 s).
    It returns `:ok` or `{:error, :timeout | :unreachable}`.

  Because a retry only ever looks at G, it can't affect a later generation. A
  test covers timeout, then the release lands, then home assigns G2, then the
  original `reclaim(G)` is retried: it returns `:ok` (G was released) and G2
  is untouched.
- **`revoke_node(node_id)`**, the forced reclaim, on home, for an unreachable
  owner. In one transaction it:
  - moves every active generation of that node to `sync_revoked` with
    `cutoff = cursor(node)`;
  - appends one `OwnershipRevoked` per generation, plus `NodeRetired`;
  - logs one compound `NodeRevoked` entry.

  It works even when the node currently holds no active generation, for
  example after a release home hasn't imported yet. Retiring a node is what
  fences it.

  Home owns all those regions from then on. Later entries carrying those
  generations are quarantined. The node becomes diverged when it imports the
  revoke, and its id can never be assigned or claimed again.
- **`owner(stream_id)`** returns `{node_id, generation}`. **`list/0`**.
- A selector is an exact name or `prefix*`. `*` anywhere else raises
  `ArgumentError`.

## Enabling, snapshots, disabling (`EventstoreSqlite.Sync`)

- **`enable(node_id)`**, on main-node. Appends `SyncEnabled{node_id, home: node_id,
  sync_id}`. Logging starts here.
- **`snapshot(path, peer: node_id)`**, on main-node. It runs serialized, through
  a provisioning lock in the `Sync` GenServer, so one snapshot runs at a time.
  It refuses an existing `path`, an existing `path.tmp`, a retired `node_id`,
  and any other current peer (A3: only one secondary-node at a time). Steps:
  1. If the peer doesn't exist, append `PeerAdded{node_id, pinned_seq: head}`
     and remember that this call created it. If it already exists and has
     never acked, keep it. The pin holds pruning from here.
  2. `VACUUM INTO "path.tmp"`.
  3. Open `path.tmp` with a raw Exqlite connection, not through the store's
     repos or API, so main-node's `Subscriptions` and `RepoWrite` are never
     involved. Set `journal_mode=DELETE` and `synchronous=FULL`, so the output
     is a single file with no `-wal` sidecar. Run `PRAGMA quick_check`. Then
     insert `SnapshotCreated{snapshot_id, for_node, snapshot_of: "main-node",
     head_seq}` as an event row plus its `"$sync"` stream rows, with raw SQL in
     one transaction. `head_seq` is read from the copy's own `sqlite_sequence`
     for `sync_log`, so it is exactly main-node's last seq contained in the copy.
  4. Close the connection. Open the file with `:file.open` and `:file.sync` it,
     which also covers the `VACUUM INTO` contents. Rename it to `path`, and
     fsync the directory where the platform allows it. The claim runs
     `quick_check` again, and the runbook compares checksums after copying.

  On failure it removes `path.tmp`. It appends `PeerRemoved` only if this call
  created the peer, the peer has never acked and it owns nothing. A test kills
  the node at the failpoint and reopens only the published file. If the node
  crashes in between, `status` shows a peer that has never acked, with its age,
  and `remove_peer` cleans it up.
- **Claiming, at boot** of a node whose configured `node_id` doesn't match the
  database identity. Allowed only if the latest `"$sync"` event is a
  `SnapshotCreated` whose `for_node` equals the configured id. Otherwise the app
  refuses to start. In one transaction, the claim:
  1. sets `sync_cursors = {snapshot_of => head_seq}`;
  2. deletes the copy's `sync_log`, `sync_log_events`, `sync_acks`,
     `sync_quarantine` and other `sync_cursors` rows;
  3. resets the `sync_log` counter with
     `DELETE FROM sqlite_sequence WHERE name = 'sync_log'`, so secondary-node seqs start
     at 1;
  4. appends `SnapshotClaimed{snapshot_id, node_id, snapshot_of, cursor}`.

  Replaying `"$sync"` defines a `SnapshotClaimed` as: identity = `node_id`,
  peers = {`snapshot_of`}, home unchanged, halted and diverged cleared.
  `"$ownership"` replays as it did on main-node, so the secondary-node knows the current
  assignments. A database that was claimed already can never be claimed again,
  because the latest `"$sync"` event is no longer a `SnapshotCreated`.
- **Identity check at every boot**: the configured `node_id` must equal the
  replayed identity, unless a claim is allowed.
- **`remove_peer(node_id)`** always requires that the peer owns no active
  generation. A live secondary-node must first release or go through `revoke_node`, so
  removing a peer can never leave a region writable on two nodes. Otherwise:
  - For a live peer without options, it also requires that the peer has acked
    our head.
  - For a retired peer, it requires instead that the peer is **drained**, and
    not an ack: a diverged peer stopped importing at the revoke, so it can
    never ack home's later head. Drained means the peer's last export
    reported it diverged, and home's cursor has reached the head that same
    export returned. A diverged node writes nothing more, so that head is
    final, and every late entry is now imported or quarantined (I3). A test
    covers revoke, then home keeps writing, then the secondary-node diverges and
    drains, then removal succeeds.
  - `discard_unpulled: true` removes the peer without the drain. It is for a
    secondary-node that is gone for good. Whatever that secondary-node wrote after the last pull is
    lost, which is a documented exception to I3, and the call logs the
    discarded range as far as it is known.

  The export response carries the exporter's state (`diverged`, `head`), so
  home can see when a peer is drained.

  The removal transaction recalculates the pruning watermark over the
  remaining peers and prunes. With no peers left, it prunes through the local
  head, so `sync_log` is empty right after the last peer is removed.

### Detecting divergence

- **On the diverged node itself:**
  - every append, archive and ownership call returns `{:error, :diverged}`;
  - `Sync.status()` reports `:diverged`, with who revoked it and when;
  - a `NodeDiverged` event in `"$sync"` lets the app subscribe to it and
    show a banner, for example;
  - `Logger.error` and the telemetry event `[:eventstore_sqlite, :sync,
    :diverged]`.
- **On main-node:**
  - after `revoke_node`, `Sync.status()` lists the node as `:retired`;
  - once the node has reconnected and reported itself diverged in an export,
    the status shows `:diverged`, then `:drained` when main-node has pulled
    everything, with the quarantine count.
  - A retired node that never shows `:diverged` hasn't reconnected since the
    revoke. Until it does, it may still be writing.
- **Before reconnecting,** a partitioned node can't know it was revoked. That
  is inherent to a forced reclaim without a lease, and a lease would conflict
  with decision 7 (the node keeps writing while main-node is unreachable).

### Administration guards

- `enable/1` is allowed only on a node with no sync history (or after
  `SyncDisabled`, see below). It makes that node home.
- `snapshot/2`, `assign/2`, `reclaim/2`, `revoke_node/1`, `remove_peer/2` and
  `disable/0` are home-only (`{:error, :not_home}` elsewhere).
- `release/1` is owner-only.
- On a diverged node, every one of these returns `{:error, :diverged}`. A
  diverged node can't remove its peer, disable sync, or otherwise return to
  writing. Rebuilding under a new id is the only way back.
- Halt and divergence are durable fences (`sync_state`, from `"$sync"`). The
  replicator checks them when it starts, and every import transaction checks
  them again inside the transaction before applying anything. A diverged node
  therefore never imports again, even after a replicator or whole-node
  restart, when its cursor is already past the revoke. A test restarts the
  replicator, restarts the node and calls `resume` after divergence, then
  checks that the cursor never advances past the revoke.
- `enable/1` is also allowed when the latest `"$sync"` event is
  `SyncDisabled`. It then starts a new replication group with a new
  `sync_id`. Repeated secondary-node sessions don't need this: main-node stays enabled and
  each secondary-node is added as a new peer.

  Replay at a `SyncEnabled` that follows `SyncDisabled`:
  - **Reset:** peers, acks, cursors and halts. The new group starts with
    none.
  - **Kept:** generations, `sync_released`, `sync_revoked`, `sync_retired`,
    and the `sync_log` seq counter. They remain valid and keep increasing, so
    an old generation or a retired id can never be confused with a new one.
    There are no active assignments, because `disable` requires none.

  A test covers enable, replicate, disable, re-enable, snapshot, claim, and
  `rebuild_state` on both nodes. A test tries
  `disable` and `remove_peer` on a diverged secondary-node.
- **`disable()`** requires that there are no peers and no active assignments.
  It appends `SyncDisabled`, then deletes the log.

## Verification (`Sync.verify(peer, mode)`)

Each side computes, in one read transaction, a **history** per stream name.
The history is the ordered list of incarnations: the archived ones in local
archive order, then the live one if there is one. Each incarnation is its list
of `(event_id, digest of type, data, metadata, inserted_at)` in version order.
An incarnation is identified by its version-0 event id, which is globally
unique. Only digests travel over `:erpc`, with per-incarnation rolling digests
so that a common prefix is cheap to compare.

- **`:prefix`**, usable under load, during handovers and around archives. For
  every stream name, one side's history must be a prefix of the other's:
  - the incarnations match one by one;
  - every incarnation except the last common one is identical, including
    whether it is archived;
  - the last common incarnation may be shorter, or still live where the other
    side has archived it.

  This needs no knowledge of ownership or timing. It catches every fork (two
  different events at the same position, or different incarnations) and
  reports the rest as lag, with counts. It doesn't detect an event that never
  arrives; quiescing and running `:strict` covers that.
- **`:strict`**, after quiesce: the histories are equal.

Tests run `:prefix` during a lagged archive, during reuse of a name, and in the
middle of a handover.

## Phases

Each phase ships with all tests passing, a CHANGELOG entry and docs. Sync stays
off unless explicitly enabled.

1. **Schema, system events, enable/disable, logging, identity, ownership
   resolution.** Includes the owner check with only the home default: a
   non-home node owns nothing, so a replica can never write. Benchmarks the
   disabled and enabled write paths.
2. **Export and import in one BEAM**, including the authorization rules, halts,
   quarantine paths, archive import through `Subscriptions.apply_archive`, and
   failpoints (below).
3. **Two-node harness, replicator, status, acks and pruning, snapshot and
   claim, `verify`.** At this point the secondary-node is a safe read-only replica, which
   is useful on its own.
4. **Ownership API**: assign, release and planned reclaim.
5. **Forced reclaim**: revocations, quarantine, diverged state, retired ids,
   `Sync.quarantine/0`.
6. **Stress harness, manual runbook tooling (`DevLoad`), docs.**

## Failpoints

`EventstoreSqlite.Sync.Failpoint.hit(name)` is a no-op unless compiled for test.
In tests it can block on a barrier, raise, or kill the node. Points:

- after an ownership transaction commits, before the reply (assign, release,
  revoke);
- after `release` commits, before the `:erpc` reply reaches home;
- after an import transaction commits, before the pings;
- inside `apply_archive`, before and after commit;
- between recording an ack and pruning;
- during a snapshot, after `VACUUM INTO` and before the rename;
- during a claim, before commit.

## Automated tests

### Single node (normal suite)

- Property tests (`stream_data`, test-only) on the pure replay function and the
  owner resolution, against a naive reference model. Includes random
  interleavings of assign, release, revoke and stale or duplicated releases,
  checking I6. `rebuild_state/0` equals the incrementally maintained tables.
- Every import path, with hand-built entries: duplicates, gap, version
  conflict, unknown generation, revoked generation goes to quarantine,
  oversized entry kept whole, archive conflict, cursor and effects atomic under
  a raise at every failpoint.
- Disabled-sync behaviour is byte-for-byte identical to today, and the existing
  suite passes untouched.

### Two nodes (tag `:cluster`, run in CI)

The harness starts `:peer` nodes with `connection: :standard_io`, so the control
channel doesn't use distribution, and `-kernel dist_auto_connect never`. The
harness alone connects the nodes (`Node.connect`) and partitions them
(`:erlang.disconnect_node`). A partition therefore lasts until the harness
lifts it.

Scenarios:

- **Mirror:** 10k events over 100 streams converge, and `verify(:strict)` is
  `:ok`.
- **Atomic batches:** a 5000-event batch becomes visible on the secondary-node in one
  transaction. A reader polling the secondary-node's `streams.stream_version` only ever
  sees 0 or 5000.
- **Crash during import:** a partition or kill at every import failpoint, then
  convergence with no duplicates.
- **`:not_owner`** on both sides according to the assignments. A replica
  without assignments can't write at all.
- **Planned handover under load:** 20 writers on the secondary-node, `reclaim` from home.
  Every write the secondary-node acked is on home, no version was accepted twice, and home
  writes after `:ok`.
- **Release reply lost** (failpoint after the release commits): `reclaim(G)`
  times out. A retry returns `:ok` and the generation isn't released twice.
- **Timeout, reassignment, retry:** `reclaim(G)` times out, the release lands,
  home assigns G2, and the original `reclaim(G)` is retried. It returns `:ok`
  (G is released) and G2 is untouched.
- **Delayed stale release, pending release then revoke:** the secondary-node releases G
  while partitioned, so it holds no generation anymore, and home runs
  `revoke_node`. Healing the partition delivers the release, and home writes
  `ReleaseIgnored`. The secondary-node imports `NodeRevoked` and becomes diverged even
  though it held nothing.
- **Revoke with several assignments:** two disjoint assignments, one of them
  released locally. `revoke_node`, then a crash at every import failpoint
  while the secondary-node imports it. Afterwards the secondary-node has all the revocations, the
  retirement and the divergence, or none of them.
- **Drain before removal:** after `revoke_node`, `remove_peer` refuses until
  the secondary-node is drained, and then succeeds. The quarantine holds every late
  entry. (A variant where the region was meanwhile assigned
  to another node is covered with hand-built entries in the single-node import
  tests, since only one secondary-node exists at a time.)
- **Out-of-scope append:** a hand-built entry from the secondary-node with an active G but
  a stream outside G's selector halts with `:ownership_violation`. So does an
  assign coming from the secondary-node.
- **Lost ping:** commit an import, kill the replicator before the ping, write
  nothing more. The subscriber still receives the events.
- **Forced reclaim of a live, partitioned writer:** the secondary-node keeps writing during
  the partition. Home runs `revoke_node` and writes to the region. The
  partition heals. Home quarantines exactly the secondary-node's append and archive
  entries it hadn't imported at revoke time (all of the secondary-node's generations were
  revoked), ignores its stale releases, and the secondary-node becomes diverged and
  refuses writes.
- **Writes racing an assignment:** home writers hammer `venue:*` while `assign`
  commits. Each write is either before the assignment (and present on the secondary-node
  before the secondary-node's first write) or rejected.
- **Overlap rejection:** `assign` of nested or overlapping selectors returns
  `{:error, :overlap}`.
- **Archive and reuse:** archive on the owner, replicated; recreate the same
  name; archive again. `verify(:strict)` compares both incarnations.
- **Snapshot under load,** then claim, then `rebuild_state` on the secondary-node produces
  the same state. Claiming the same file again, or claiming with the wrong
  node id, refuses to boot.
- **Pruning:** empty after both acks. A never-acked peer pins pruning. A
  requester behind the pruned range halts with `:pruned`.
- **Mismatches:** protocol, `sync_id`, `expect` or an `ahead_of_origin` cursor
  each halt.

### Automated stress test (`mix eventstore.sync_stress`, also `@tag :stress`)

A seeded, randomized run against the same two-node harness. It defaults to
5 minutes in a nightly CI job and can run for hours.

- **Load:** N writers per node (default 8), appending batches of 1–50 events to
  streams under the selectors the harness model says the node owns.
- **Model:** the harness keeps its own model of ownership, generations, and
  stream incarnations (a stream name gets a new incarnation after each archive).
  Every operation is recorded as attempted, with its result: `:ok`, an error,
  or unknown when the node died during the call. After a crash, unknown
  outcomes are reconciled by reading both nodes.
- **Chaos, at random:**
  - assign, release, and planned reclaim (also with lost replies);
  - archive on the owner;
  - partitions from 0.1 to 30 s;
  - killing a replicator;
  - brutal kills and restarts of either node, including during import and
    during archive at the failpoints.
- **Ending with a forced phase:** partition, `revoke_node` of the live secondary-node,
  and heal.
- **Continuous checks:**
  - no `(stream incarnation, version)` is ever acked by two nodes, outside the
    forced phase;
  - per-node subscribers see versions per incarnation in order, with no
    duplicates and no gaps, except a missing tail of an archived incarnation,
    which is dropped by design. They resubscribe after
    `{:stream_archived, _}`;
  - `verify(:prefix)` every 10 s.
- **At quiesce:**
  - `verify(:strict)` passes, before the forced phase;
  - every acked write is live, or archived in the incarnation the model
    expects, on both nodes;
  - `"$all"` on each node holds each live event exactly once, in per-origin
    order;
  - the quarantine equals exactly the model's prediction for the forced phase;
  - after the forced phase, the harness checks the quarantine, waits for the
    secondary-node to drain, and removes it. Only then does it assert that `sync_log` is
    empty, since a diverged secondary-node can never ack home's later entries.
- **Output:** seed, throughput, lag p50/p99/max, handover durations, number of
  halts (must be 0 before the forced phase), and violations with the seed to
  replay.
- **Benchee:** append latency with sync off, sync on with the peer connected,
  and sync on with the peer down.

## Manual stress test runbook (for the owner)

Tooling is `EventstoreSqlite.Sync.DevLoad`, which runs only in dev:

- `start(selectors, rate)`: writers append at a target rate.
- `stop()`.
- `stats()`: acked writes, `:not_owner` count, errors.

The runbook uses two machines on a LAN if possible, otherwise two terminals.

1. main-node: `NODE_ID=main-node DB=main-node.db iex --name main_node@host -S mix`, then
   `Sync.enable("main-node")`.
2. main-node: `DevLoad.start(["orders:*"], 200)`, running throughout.
3. main-node: `Sync.snapshot("secondary-node.db", peer: "secondary-node-1")` under load. Copy `secondary-node.db` to
   the second machine and check that `sha256sum` matches.
4. secondary-node: `NODE_ID=secondary-node-1 DB=secondary-node.db iex --name secondary_node@host2 -S mix` claims the copy.
   Then `Node.connect(:"main_node@host")`. `Sync.status()` reaches lag 0, and
   `Sync.verify("main-node", :prefix)` is `:ok`. Writing any stream on the secondary-node
   returns `:not_owner`.
5. main-node: `Ownership.assign("venue:*", "secondary-node-1")`. secondary-node:
   `DevLoad.start(["venue:*"], 200)`. On main-node, writing `venue:1` returns
   `{:error, :not_owner}`, and `assign("venue:vip", "secondary-node-1")` returns
   `{:error, :overlap}`.
6. **Network loss:** drop the traffic (`sudo iptables -A INPUT -s <other> -j
   DROP` on one side, or unplug the cable) for 2 minutes, and for 15 minutes
   once. Both keep writing, and the status shows `:disconnected`. Restore it
   and time the catch-up. Run `verify(:prefix)`, then stop the loads briefly
   and run `verify(:strict)`.
7. **Crashes:** `kill -9` the secondary-node under load, then restart it. Same for main-node.
   Run `verify` after each.
8. **Disk-level sanity:** after step 7, run `PRAGMA integrity_check` on both
   files.
9. **Archive:** on the secondary-node, `archive_stream("venue:1")`. Check it is archived
   on main-node, then write `venue:1` again on the secondary-node and check it is recreated on
   main-node.
10. **Subscribers:** in the app (for example tickets-admin), keep a LiveView
    open on the secondary-node for a stream main-node writes and one for a stream the secondary-node writes.
    Both update live, including after step 6.
11. **Planned handover:** main-node runs `Ownership.reclaim(g)` (with `g` from
    `Ownership.owner("venue:1")`) while the secondary-node load runs. The secondary-node writers flip to `:not_owner`, and `reclaim` returns
    `:ok`. Note the duration. Then on main-node, `DevLoad.start(["venue:*"], 200)`.
    Run `verify(:strict)` after stopping the loads.
12. **Forced reclaim:** first `Sync.remove_peer("secondary-node-1")` and stop secondary-node-1. Then
    set up a fresh secondary-node: `snapshot` for `"secondary-node-2"`, claim, `assign("venue:*",
    "secondary-node-2")`, and load on the secondary-node. Cut the network. main-node runs
    `Ownership.revoke_node("secondary-node-2")` and writes `venue:*`. Restore the network. main-node's `Sync.quarantine()` lists the secondary-node's
    un-imported entries. The secondary-node's `Sync.status()` says `:diverged`, and its
    appends return `{:error, :diverged}`.
13. **Teardown:** wait until main-node's `Sync.status()` shows secondary-node-2 as `:diverged`
    with lag 0 (drained). Then `Sync.remove_peer("secondary-node-2")` and
    `Sync.disable()`.
    `sync_log` is empty.
14. Throughout, watch `:observer` (memory and message queues of the replicator
    and `Subscriptions`) and the size of the database and WAL files.

Pass criteria:

- `verify` is `:ok` after every step from 4 to 11;
- there are no halts outside step 12;
- catch-up after a 2-minute outage at 200 events/s per node takes under 10 s;
- `integrity_check` is ok.

## Out of scope

- Forwarding writes to the owner.
- Automatic failover.
- More than two nodes.
- Overlapping or nested assignments (A10).
- Reading or unarchiving archives.
- Changes in consumers: handling `:not_owner`/`:diverged`, per-node
  checkpoints, and resubscribing after 0009.
