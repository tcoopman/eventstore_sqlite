# Issue — events read from `$all` don't say which stream they came from

- **Status:** Done 2026-10-02 (track original_stream_id for $all). The
  migration took 3.2 s on a copy of `bench.db` (696 585 `$all` rows).
- **Found via:** brainstorming `archive_stream` (0005). A `$all` projection told
  that a stream was archived can't find that stream's events.

## Problem

An event read from `$all` (`stream_forward("$all")`, or a `$all` subscription)
looks like this:

```elixir
%RecordedEvent{stream_id: "$all", stream_version: 41, ...}
```

`stream_version` is the event's position in `$all`. Nothing in the event tells
which stream it was appended to, or its version in that stream. `Reader.fetch_chunk/5`
selects `s.stream_id` and `s.stream_version` from the `stream_events` row it read,
and for `$all` that is the `$all` row.

`stream_events` already has `original_stream_id` and `original_stream_version`
columns, but they are wrong for `$all` rows written by `append_to_stream`.
`insert_in_stream/3` binds

```elixir
[event.id, stream_id, version, stream_id, version]
```

for every stream it writes, including `$all`. So a `$all` row records `"$all"` and
its own position as its "original". Only `Migration.intial_fill_all/0` fills the
columns correctly for `$all`.

## Proposed change

1. **Writes.** `append_to_stream` passes the real origin when it writes the `$all`
   rows: `original_stream_id` = the stream appended to, `original_stream_version` =
   the event's version there. Rows for the stream itself stay as they are (origin =
   itself).
2. **Existing rows.** A migration fixes the `$all` rows written so far. The
   `no_update_stream_events` trigger blocks `UPDATE`, so the migration drops the
   trigger, updates, and recreates it in one transaction:

   ```sql
   DROP TRIGGER no_update_stream_events;

   UPDATE stream_events AS a
   SET original_stream_id = o.stream_id,
       original_stream_version = o.stream_version
   FROM stream_events AS o
   WHERE a.stream_id = '$all'
     AND o.event_id = a.event_id
     AND o.stream_id <> '$all';

   CREATE TRIGGER no_update_stream_events ...;  -- unchanged
   ```

   This relies on every `$all` row having **exactly one original stream**: one
   non-`$all` row with the same `event_id`. That should hold (there is no link API, and a
   duplicate event id fails the append), but the migration doesn't trust it:
   - **No original stream** (e.g. a row from an earlier direct `append_to_stream("$all", …)`):
     `UPDATE … FROM` skips the row, which keeps its wrong, non-NULL `"$all"`
     origin.
   - **Several original streams:** SQLite picks one of them arbitrarily.

   Neither case can be repaired by the `coalesce` fallback below, because the old
   values aren't NULL. So, inside the same transaction and before the `UPDATE`,
   the migration counts both cases:

   ```sql
   SELECT
     coalesce(sum(original_streams = 0), 0) AS without_original_stream,
     coalesce(sum(original_streams > 1), 0) AS with_several_original_streams
   FROM (
     SELECT (SELECT count(*) FROM stream_events o
             WHERE o.event_id = a.event_id AND o.stream_id <> '$all') AS original_streams
     FROM stream_events a
     WHERE a.stream_id = '$all'
   );
   ```

   `sum` over no rows is NULL in SQLite, hence the `coalesce`: a store with an
   empty `$all` must pass. If either is non-zero it raises, which rolls back the transaction (trigger
   included), with an actionable message: how many rows of each kind, the query
   that lists them (`event_id` and `$all` position), and that they must be
   repaired by hand before migrating again. After the `UPDATE` it also asserts
   that no `$all` row still has `original_stream_id = '$all'`.

   `stream_events` has no index on `event_id`, which made both the check and the
   `UPDATE` quadratic (still running after 10 minutes on `bench.db`). The
   migration creates a temporary `event_id` index for them and drops it again.

   `UPDATE … FROM` needs SQLite ≥ 3.33. Use correlated sub-selects if an older
   one has to be supported.
3. **Reads.** `Reader.fetch_chunk/5` also selects `s.original_stream_id` and
   `s.original_stream_version`, and `RecordedEvent` gets two new fields:

   ```elixir
   %RecordedEvent{
     stream_id: "$all", stream_version: 41,
     original_stream_id: "ada", original_stream_version: 3
   }
   ```

   For events read from their own stream, the fields equal `stream_id` /
   `stream_version`.
4. **Index.** `(original_stream_id, original_stream_version)` on `stream_events`,
   so "the `$all` rows of stream X" doesn't scan `$all`. 0005 needs this when it
   removes an archived stream's `$all` rows.
5. **Refuse direct appends to `$all`.** `append_to_stream("$all", events)` is
   accepted today. It writes the events into `$all` twice (once as "the stream",
   once as `$all`) with `"$all"` as their origin, which breaks the origin fields
   above. It returns `{:error, :system_stream}` and writes nothing, the same error
   `archive_stream` uses in 0005. 0005 adds `$archives` to the refused names.

## Backward compatibility

- **`stream_id` and `stream_version` keep their meaning.** For a `$all` event they
  are still `"$all"` and the `$all` position. Subscribers save that position as
  their checkpoint, and existing tests and pattern matches rely on it
  (`stream_forward([stream_1, "$all"])`, `subscribe_test.exs`). Putting the
  origin into `stream_id` instead would make `stream_version` ambiguous and
  silently break every saved `$all` checkpoint.
- **New struct fields get defaults.** `RecordedEvent` uses
  `typedstruct enforce: true`. Declare the two new fields with `default: nil` so
  callers who build `%RecordedEvent{}` themselves (consumer test fixtures) don't
  start failing at compile time. Pattern matches on `%RecordedEvent{...}` ignore
  extra fields.
- **The schema change is additive.** It adds an index and fixes values in
  columns nobody reads yet. Code built before this change ignores both.
- **NULL fallback only.** `Reader` selects
  `coalesce(s.original_stream_id, s.stream_id)` (and the same for the version), so
  a row with NULL origin columns returns itself as its origin instead of `nil`.
  It does **not** cover wrong values. A `$all` row with origin `"$all"`, the state
  of every `$all` row before the migration, is returned as-is. Correct `$all`
  origins therefore depend on the migration having run, and the migration
  refuses to finish while any row would stay wrong.
- **Refusing appends to `$all` is a behaviour change**, but such an append only
  ever produced duplicated, corrupt `$all` rows, so no correct caller relies on
  it. The new `{:error, :system_stream}` is an extra return value of
  `append_to_stream` and goes in its `@doc`.

## Rollout

Stop every process running the old version before the migration runs, and don't
start an old version again afterwards. The old `insert_in_stream` keeps writing
`"$all"` as the origin of new `$all` rows, and the migration only fixes the rows
that exist when it runs. The reader's `coalesce` doesn't help, because those
values aren't NULL. (Raised in the gpt-luna review.)

## Open points

- The migration enforces the exactly-one-original-stream rule itself, but run its check query
  on existing stores (tickets-admin prod) before deploying, so a failing
  migration doesn't come as a surprise during the rollout.

## Tests

- A `$all` read and a `$all` subscription return the origin stream and version
  for events from several streams.
- A single-stream read returns origin = itself.
- The migration fixes `$all` rows written by the old `insert_in_stream` (write
  rows the old way, migrate, read back) and leaves the trigger in place
  afterwards (an `UPDATE` still fails).
- The migration aborts, changes nothing and keeps the trigger when a `$all` row
  has no original stream (a direct `$all` append written the old way), and likewise when
  an event has two non-`$all` rows. The error names the count and the query.
- The migration succeeds on an empty store (no `$all` rows).
- `append_to_stream("$all", events)` returns `{:error, :system_stream}` and
  writes nothing, for every `expected_version`.
