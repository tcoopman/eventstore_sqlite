# Changelog

All notable changes to EventstoreSqlite are documented here. No versioned
changelog releases are maintained, so entries are grouped by date (ISO 8601,
`YYYY-MM-DD`). The categories follow
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [2026-10-09]

### Breaking

- **The names `"$sync"` and `"$ownership"` are now reserved.** The new
  migration refuses to run on a store that already has a stream with either
  name. This must return `0`:

  ```sql
  SELECT count(*) FROM streams WHERE stream_id IN ('$sync', '$ownership');
  ```

- `append_to_stream/3` and `archive_stream/2` can return
  `{:error, :not_owner}` and `{:error, :diverged}`, but only once sync has been
  enabled with `EventstoreSqlite.Sync.enable/1`. A store without sync behaves
  as before.

### Added

- Sync between two stores with one writer per stream
  (`EventstoreSqlite.Sync`). See `docs/issues/0008-multi-node-sync-plan.md`.
  - A store can be made the home node of a replication group with
    `EventstoreSqlite.Sync.enable/1`. From then on every append and archive is
    recorded in a change log in the same transaction, and every write is
    checked against stream ownership. By default the home node owns every
    stream. The log stays empty while sync is disabled.
  - Sync state is kept as system events in `"$sync"` and `"$ownership"`. Like
    `"$archives"`, neither appears in `"$all"`.
  - A node pulls the entries of its peer with `EventstoreSqlite.Sync.export/1`
    and applies them unchanged: the same event ids, timestamps and bytes.
    Subscribers receive imported events like local ones. An entry that would
    break the single-writer rule halts replication from that peer
    (`EventstoreSqlite.Sync.resume/1` clears the halt after a repair).
    Entries written under a revoked ownership generation are quarantined
    (`EventstoreSqlite.Sync.quarantine/0`).
  - Provision the second node from `EventstoreSqlite.Sync.snapshot/2`: a
    consistent copy of the home node's database that only the named node can
    claim, once, at its first boot. Each node then runs a replicator per peer
    that pulls over Erlang distribution (nodes find each other by node id
    through `:pg`; the application connects the nodes). Replication survives
    partitions and restarts, since the cursor is stored with the data.
  - `EventstoreSqlite.Sync.status/0` reports each peer's state, lag,
    acknowledgements and quarantine. `EventstoreSqlite.Sync.verify/2`
    compares both nodes' stream histories by content, also while they write.
    `EventstoreSqlite.Sync.remove_peer/2` removes a peer once it is caught up.
  - `EventstoreSqlite.Ownership` assigns streams, by exact name or trailing
    `*` prefix, from the home node to the other node (`assign/2`), hands them
    back without losing a write (`reclaim/2`, `release/1`), or takes them back
    at once from an unreachable node (`revoke_node/1`). A revoked node's
    unpulled writes to those streams are quarantined; when it reconnects it
    becomes diverged and refuses every write until it is rebuilt from a new
    snapshot under a new node id. Assignments can't overlap.
  - Configure the node id with `config :eventstore_sqlite, :sync, node_id: "…"`.
    A store with sync enabled refuses to start under another node id, or
    without one.

### Fixed

- Subscribers of a stream could miss events for good when the process that
  appended them died between the commit and notifying the subscription
  process, if nothing was appended to that stream afterwards. The subscription
  process now also checks every subscribed stream for undelivered events once
  a second. Set `config :eventstore_sqlite, subscription_reconcile_interval: ms`
  to change the interval.

### Changed

- An append reads the sync state in its transaction. With sync disabled this
  costs about 18 µs per append (about 5% of a single-event append). With sync
  enabled, writing the log adds about 28%.

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
