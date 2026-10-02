# Issue — numeric-looking stream names come back as numbers, or can't be appended to at all

- **Status:** Built 2026-10-02, in review. Reproduced first with a script
  against a fresh database. The migration took 2.6 s on a copy of `bench.db`
  (1 393 170 `stream_events` rows).
- **Found via:** reviewing the `list_streams/0` docs.

## Problem

`stream_events.stream_id` and `stream_events.original_stream_id` were created
by `references(:streams, column: :stream_id)` in the first migration, which
declares them with SQLite **INTEGER affinity**:

```sql
"stream_id" INTEGER CONSTRAINT "stream_events_stream_id_fkey" REFERENCES "streams"("stream_id"),
"original_stream_id" INTEGER CONSTRAINT "stream_events_original_stream_id_fkey" REFERENCES "streams"("stream_id"),
```

`streams.stream_id` itself is `TEXT`. SQLite stores text written to an INTEGER
column as a number whenever it is a well-formed number, even when that loses
the original spelling (`"007"` becomes `7`, `"1e3"` becomes `1000`), so the two
tables disagree about numeric-looking stream names.

## Measured

Appending one event to each name, then reading it back with
`read_stream_forward/1` and from `"$all"`:

| stream name | append | `stream_id` read back | `original_stream_id` in `$all` |
|---|---|---|---|
| `"abc"` | `:ok` | `"abc"` | `"abc"` |
| `"123"` | `:ok` | `123` (integer) | `123` |
| `"-5"` | `:ok` | `-5` (integer) | `-5` |
| `"1.5"` | `:ok` | `1.5` (float) | `1.5` |
| `"007"` | raises `FOREIGN KEY constraint failed` | — | — |
| `"1e3"` | raises `FOREIGN KEY constraint failed` | — | — |
| `" 42"` | raises `FOREIGN KEY constraint failed` | — | — |
| `"99999999999999999999"` | raises `FOREIGN KEY constraint failed` | — | — |

- **Wrong type.** For `"123"`, reads, `$all` reads and subscriptions return a
  `RecordedEvent` whose `stream_id` / `original_stream_id` is the integer `123`
  (subscription to `"123"` delivered `stream_id: 123`). Code that matches on
  the string, or uses it as a map key, silently misses these events.
- **Append fails.** For `"007"` the stream row stores `'007'` (TEXT) but the
  event row stores `7`. The foreign key compares them with the parent's TEXT
  affinity (`'7'` ≠ `'007'`) and the whole append raises.
- **Unaffected:** `list_streams/0` (reads `streams`, TEXT), `expected_version`
  checks (also `streams`), and the archive tables from 0005 (`stream_id` is
  TEXT). Lookups by name still find the rows, because the comparison applies the
  column's affinity to the parameter.

## Proposed change

A migration that rebuilds `stream_events` with TEXT columns. SQLite can't change
a column's type in place, so:

1. Create `stream_events_new` with `stream_id` and `original_stream_id` as
   `TEXT` (same foreign keys, same other columns).
2. `INSERT INTO stream_events_new SELECT id, event_id, CAST(stream_id AS TEXT),
   stream_version, CAST(original_stream_id AS TEXT), original_stream_version
   FROM stream_events`. This recovers the original names exactly, because of
   the foreign key: it compares a stored number with `streams.stream_id` as
   text, so a number could only be stored if its text form equals the stream's
   name. That is also why the lossy names (`"007"`) never got in.
3. Drop the old table and recreate its indexes (`(stream_id, stream_version)`
   unique, `(original_stream_id, original_stream_version)` from 0004) and the
   `no_update_stream_events` trigger.

As built (`Migration.rebuild_stream_events/2`): the old table is renamed to
`stream_events_old` first, and the indexes and triggers are recreated from the
SQL stored in `sqlite_master`, read before the rename. Every row keeps its `id`
(multi-stream reads are ordered by it), and the AUTOINCREMENT counter is carried
over, so ids of rows deleted by an archive are never reused. The migration's
`down` runs the same rebuild with INTEGER columns. Once a stream with a name
like `"007"` exists, `down` can't succeed (the old schema can't store that
name): it raises an explanation and changes nothing. (Raised in the gpt-luna
review.)
4. `archived_stream_events` references `events`, not `stream_events`, so it
   doesn't need to change.

After the copy, `PRAGMA foreign_key_check(stream_events)` must be empty;
otherwise the migration raises and rolls back. That catches rows written while
foreign keys were off, which the argument above doesn't cover.

Cost: one copy of `stream_events`. Based on the 0004 and 0006 timings
(about 3 s for 700k rows on `bench.db`), expect a few seconds per million rows.
Measure on `bench.db` before deploying.

## Before deploying

Check whether any existing store has numeric stream names, because their
consumers currently receive numbers and will receive strings afterwards:

```sql
SELECT DISTINCT stream_id, typeof(stream_id) FROM stream_events WHERE typeof(stream_id) <> 'text';
```

If tickets-admin prod returns rows, its code that handles those events has to
be checked for code that relies on the number.

## Tests

- Append, read, read `$all`, subscribe and archive with `"123"`, `"-5"`,
  `"1.5"`, `"007"`, `"1e3"`, `" 42"` and a 20-digit name: every append
  succeeds and every `stream_id` / `original_stream_id` is the original string.
- The migration converts existing integer and float `stream_id` /
  `original_stream_id` values back to the original strings, keeps the indexes
  and the update trigger, and leaves `PRAGMA foreign_key_check` empty.
