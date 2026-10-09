# Changelog

All notable changes to EventstoreSqlite are documented here. No versioned
changelog releases are maintained, so entries are grouped by date (ISO 8601,
`YYYY-MM-DD`). The categories follow
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [2026-10-10]

### Breaking

- **Run the new migration, which adds `applied_at` to `sync_cursors`, before
  starting the new version.** Replication writes it whenever it applies a
  peer's entries, and `EventstoreSqlite.Sync.status/0` reads it: without the
  migration, both fail on a store with sync enabled. Stores without sync are
  unaffected. Rolling the migration back is safe.

### Added

- `EventstoreSqlite.stream_info/1` and `EventstoreSqlite.list_stream_infos/1`
  return `%EventstoreSqlite.StreamInfo{}`: a stream's version, the times of
  its first and last event, and with sync enabled its owner, without reading
  its events. The list is ordered by name, or with `order: :newest` by
  creation on this node, newest first. It is searchable anywhere in the name
  (`:search`, ignoring ASCII case), paged with a cursor (`:after` takes the
  previous page's `next`, `:limit`), and lists system streams on request
  (`:system`).
- `EventstoreSqlite.subscribe_to_changes/1`: the subscriber receives
  `{:eventstore_sqlite, :changed, kinds}`, with `kinds` from `[:streams,
  :sync]`, when streams are appended to or archived (here or by an import),
  ownership or sync state changes, or a peer's replication status changes.
  Coalesced to about one message a second per subscriber
  (`config :eventstore_sqlite, changes_interval: ms`).
- `EventstoreSqlite.Sync.status/0` also returns `log: %{oldest, entries}`, the
  change log entries retained for peers, and per peer `last_applied_at`, when
  this node last applied one of its entries. Its documentation now lists
  every field.
- **live_eventstore**, a read-only LiveView dashboard to mount in a Phoenix
  router, like LiveDashboard: `import EventstoreSqlite.LiveEventstore.Router`,
  then `live_eventstore "/eventstore"` inside a scope that pipes through your
  browser pipeline. It shows:
  - every stream with its version, creation time and last event time,
    searchable by name and paged, with system streams on request;
  - with sync enabled, this node's role, its peers (state, lag, last applied
    entry, last success, acknowledged entry, quarantined entries, owned
    generations, halts and errors), the change log, the ownership
    assignments with each stream's owner, and recent `"$sync"` and
    `"$ownership"` events.

  It updates through `subscribe_to_changes/1`, with a refresh every 30 s for
  writes it isn't told about, and only uses the public API. It serves its own
  JavaScript, built from the application's `phoenix` and
  `phoenix_live_view` packages, so it needs no asset build. Options:
  `:on_mount` (for authentication), `:live_socket_path`,
  `:live_session_name`. Put it behind authentication.
  `dev/live_eventstore_demo.exs` serves it on a demo store.

### Changed

- `phoenix_live_view` is an optional dependency. Applications without it are
  unaffected: the dashboard modules are only compiled when it is present.
- Development dependencies: `mneme` is pinned to 0.9.3, which lets dev and
  test use current LiveView (it conflicted through `igniter`). That also
  removed `mint` and `hpax` from the lock file. `bandit` was added for the demo
  server.

## [2026-10-09]

### Breaking

- **Run the new migration, which reserves `"$sync"` and `"$ownership"`.** It
  creates the sync tables and refuses to run, changing nothing, on a store that
  already has a stream with either name. This must return `0` before
  upgrading:

  ```sql
  SELECT count(*) FROM streams WHERE stream_id IN ('$sync', '$ownership');
  ```

  Appending to or archiving either name now returns
  `{:error, :system_stream}`. Rolling back the migration is refused once sync
  has been enabled.

- **Once sync is enabled, appends and archives have new errors.**
  `append_to_stream/3` and `archive_stream/2` return `{:error, :not_owner}` for
  a stream another node owns, and `{:error, :diverged}` on a node whose
  ownership was revoked. A store that never enabled sync never returns them.

- **A store with sync enabled only starts under its own node id.** Configure
  it with `config :eventstore_sqlite, :sync, node_id: "…"`. When the database
  belongs to another node id, or none is configured, the application fails to
  start with an error naming the expected id. A store that never enabled sync
  starts as before, with or without the setting.

### Added

- **Sync between two stores, with exactly one writer per stream**
  (`EventstoreSqlite.Sync`, `EventstoreSqlite.Ownership`). Each node keeps its
  own SQLite database, and both hold every event.
  - `Sync.enable/1` makes a store the home node. `Sync.snapshot/2` copies it
    for a second node, which claims the copy at its first boot. The nodes then
    replicate in both directions over Erlang distribution: they find each other
    by node id, and the application only connects the nodes.
  - Imported events keep their ids, timestamps and bytes. Stream versions are
    identical on both nodes; `"$all"` is per node, in arrival order.
    Subscribers receive imported events like local ones.
  - The home node owns every stream by default. `Ownership.assign/2` gives
    streams, by exact name or trailing `*` prefix, to the other node, and
    `Ownership.reclaim/2` takes them back without losing a write. When the other
    node is unreachable, `Ownership.revoke_node/1` takes everything back at
    once: its unpulled writes are quarantined (`Sync.quarantine/0`), and the
    node refuses every write from then on and has to be rebuilt from a new
    snapshot.
  - An entry that would break the single-writer rule stops replication from
    that peer instead of being applied (`Sync.resume/1` after a repair).
  - `Sync.status/0` reports each peer's state and lag. `Sync.verify/2`
    compares both nodes' streams by content, also while they write.
    `Sync.remove_peer/2` and `Sync.disable/0` end replication.
  - Telemetry events: `[:eventstore_sqlite, :sync, :import | :lag | :halt |
    :quarantine | :diverged]`.
  - Design, review and the reasoning behind every rule:
    `docs/issues/0008-multi-node-sync.md`, `docs/issues/0008-multi-node-sync-plan.md`
    and `docs/issues/0008-multi-node-sync-review.md`.
- `mix eventstore.sync_stress`: a seeded, randomized two-node stress test with
  partitions, node and replicator kills, handovers, archives and a forced
  reclaim. It checks that no acknowledged write is lost and that both nodes end
  up identical. `SYNC_STRESS_SECONDS` sets the duration (default 300) and
  `SYNC_STRESS_SEED` replays a run. `docs/sync-manual-stress-test.md` is the
  manual counterpart, with a load generator, `EventstoreSqlite.Sync.DevLoad`,
  in the dev environment. The dev config reads `DB` and `NODE_ID` from the
  environment.

### Fixed

- **Documented how subscribers survive a restart of the subscription
  process.** When `EventstoreSqlite.Subscriptions` crashes, for example on an
  upcaster that raises, its supervisor restarts it without any subscriptions,
  and subscribers aren't told. A subscriber that doesn't watch for this
  silently stops receiving events. This was always the case. Every subscriber
  must now monitor `EventstoreSqlite.Subscriptions` and resubscribe from its
  own position; `EventstoreSqlite.subscribe_to_stream/5` documents the pattern
  under "When the subscription process stops". **Check your subscribers**
  (projections, LiveViews) against it.

- **Subscribers could miss events for good.** This happened when the process
  that appended them died between the commit and notifying the subscription
  process, and nothing was appended to that stream afterwards. See the
  subscription check under Changed.

### Changed

- **Every append reads the sync state in its transaction.** With sync disabled
  this costs about 18 µs per single-event append (about 5%). With sync
  enabled, the ownership check and the change log entry add about 28%. See
  "Cost" in `EventstoreSqlite.Sync`.
- **The subscription process checks once a second for undelivered events.** On
  an idle store this is one primary-key read per second. When rows were
  written since the last check, it compares each subscribed stream's version
  with what it delivered. Set
  `config :eventstore_sqlite, subscription_reconcile_interval: ms` to change
  the interval.
- `telemetry` is now a direct dependency. It was already present through Ecto.
- The application starts a `:pg` scope and a sync supervisor. Neither does
  anything until sync is enabled.

## [2026-10-02]

### Breaking

- **Run these checks before upgrading: the migrations refuse to run on a store
  that fails them.** The migrations abort, leaving the store unchanged, but an
  application that migrates on boot will then fail to start.

  Every `"$all"` row must belong to exactly one application stream. Rows
  without one are left behind when a stream's rows are deleted from
  `stream_events` by hand (instead of with `archive_stream/2`), or by an old
  direct append to `"$all"`. This must return `0`:

  ```sql
  SELECT count(*) FROM stream_events a
  WHERE a.stream_id = '$all'
    AND (SELECT count(*) FROM stream_events o
         WHERE o.event_id = a.event_id AND o.stream_id <> '$all') <> 1;
  ```

  The name `"$archives"` is now reserved, so no stream may already use it.
  This must return `0`:

  ```sql
  SELECT count(*) FROM streams WHERE stream_id = '$archives';
  ```

  Repair any rows the first query finds before upgrading; the error message of
  the failing migration lists them.

  The usual case is `"$all"` rows whose stream rows were deleted by hand. Those
  events no longer belong to any stream, so their `"$all"` rows can be removed.
  Back up the database first, then run this while the application is stopped:

  ```sql
  BEGIN IMMEDIATE;
  DELETE FROM stream_events
  WHERE stream_id = '$all'
    AND NOT EXISTS (SELECT 1 FROM stream_events o
                    WHERE o.event_id = stream_events.event_id AND o.stream_id <> '$all');
  COMMIT;
  ```

  This removes only `"$all"` rows; the `events` rows stay. The removed events'
  `"$all"` positions become gaps and are not reused. Afterwards the first query
  must return `0`. If it doesn't, some events appear in more than one stream;
  those rows have to be repaired by hand.

- **Numeric-looking stream names are now returned as strings.** Before this
  change, `stream_events` stored stream IDs with SQLite INTEGER affinity, so an
  event appended to a stream such as `"123"`, `"-5"` or `"1.5"` was read back
  with `stream_id` and `original_stream_id` as the number `123`, `-5` or `1.5`.
  This applied to reads, `"$all"` reads and subscription messages. They are
  now the original strings. Code that matched on, compared with or keyed by the
  numeric value must use the string. `list_streams/0` already returned strings
  and is unchanged.

  Names whose numeric form loses their spelling, such as `"007"`, `"1e3"`,
  `" 42"` or very long digit strings, previously could not be appended to at
  all (the append raised `FOREIGN KEY constraint failed`). They now work.

  To see whether a store is affected before upgrading, run:

  ```sql
  SELECT DISTINCT stream_id, typeof(stream_id) FROM stream_events WHERE typeof(stream_id) <> 'text';
  ```

  Any row it returns is a stream whose consumers currently receive a number.

  The migration rebuilds the `stream_events` table (about 2.6 s for 1.4 million
  rows). Once a stream with a name like `"007"` exists, rolling back this
  migration is not possible: the rollback raises and changes nothing.

### Added

- Upcast events as they are read with `EventstoreSqlite.Upcaster`. Configure
  `config :eventstore_sqlite, upcasters: [MyApp.EventUpcaster]` to turn stored
  events into their current shape for every read and subscription, without
  changing what is stored. `EventstoreSqlite.Upcaster.rename/2` reads events
  whose struct module has moved, including structs nested in the event or its
  metadata.
- Preserve the original stream ID and version on recorded events, including
  events read from `"$all"`; migrate existing `$all` rows to populate this
  provenance.
- Archive whole streams while retaining their event records and stream versions
  in archive tables. Archived stream names can be reused, and each archive has
  its own ID.
- Publish `SystemEvents.StreamArchived` events to the `"$archives"` system
  stream and notify subscribers when their stream is archived.
- Rebuild `"$all"` positions from live non-system streams.
- Migrate stream ID columns to SQLite `TEXT` so numeric-looking stream names
  remain strings and retain their original spelling.

### Changed

- Reserve `"$all"` and `"$archives"`; direct appends to either now return
  `{:error, :system_stream}`.
- Archiving removes the archived stream's rows from `"$all"` without
  renumbering or reusing positions. `$all` positions may therefore contain
  gaps after an archive.
- Appending to a stream name after it has been archived starts a new stream at
  version `0`. Archived event IDs remain reserved and cannot be reused.
- Multi-stream reads follow stream-event insertion order.

### Fixed

- Make the stream of origin and its version available to projections reading
  `"$all"`.
- Preserve existing stream-event row IDs and the AUTOINCREMENT counter when
  rebuilding the `stream_events` table, so IDs of deleted rows are not reused.

## [2026-09-28]

### Added

- Configure the database chunk size for lazy forward and backward reads.
- Configure the maximum batch size delivered to each subscription message.

### Changed

- Decode missing or legacy-null metadata as an empty map (`%{}`).

## [2026-09-22]

### Added

- Attach metadata and optional caller-supplied UUIDs to events with
  `EventstoreSqlite.NewEvent`.

## [2026-07-03]

### Added

- Subscribe from `:current` to skip the stream history that exists when the
  subscription is registered and receive later appends.

### Fixed

- Remove dead subscribers and their stream subscriptions when their processes
  terminate.

## [2026-06-04]

### Fixed

- Treat stream IDs as SQL parameter values rather than interpolating them into
  SQL, including IDs containing quotes or SQL-looking text.
- Reset test data safely while preserving the event immutability trigger.

## [2025-10-30]

### Added

- Lazy, chunked `stream_forward/2` and `stream_backward/2` APIs for reading
  streams without loading the complete result into memory.

## [2025-05-10]

### Added

- `list_streams/0` to list the stream names currently present in the store.

## [2024-09-20]

### Added

- Process-based stream subscriptions that replay history and deliver newly
  appended events as `{:events, events}` messages.

## [2024-05-16]

### Changed

- Split database access into separate read and write repositories.

## [2023-12-13]

### Added

- Read several streams together, optionally specifying an inclusive start
  version for each stream.

## [2023-12-04]

### Added

- Read streams newest-first with `read_stream_backward/2` and
  `stream_backward/2`.
- Increase the default limit for list-returning reads and allow callers to
  request an unlimited result with `count: nil`.

## [2023-11-27]

### Added

- Guard appends with an expected stream state: `:no_stream`, `:stream_exists`,
  or `{:version, n}`.

## [2023-11-21]

### Changed

- Serialize event payloads using Erlang term encoding so Elixir structs and
  nested values round-trip without JSON conversion.

## [2023-11-20]

### Added

- Initial SQLite-backed event store with append-only streams, recorded events,
  and forward reads.
