# Changelog

All notable changes to EventstoreSqlite are documented here. No versioned
changelog releases are maintained, so entries are grouped by date (ISO 8601,
`YYYY-MM-DD`). The categories follow
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [2026-10-02]

### Breaking

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
