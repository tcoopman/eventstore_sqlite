# Issue — rebuilding `$all` leaves a high-water mark that the next append collides with

- **Status:** Open (noted 2026-10-02). Not reproduced by a test yet; found by
  reading `Migration.intial_fill_all/0` while designing 0005, and confirmed in
  review. Blocks 0005.
- **Found via:** 0005 (archive stream) needs the rebuild to skip `$archives`.

## Problem

`Migration.intial_fill_all/0` deletes every `$all` row and inserts one `$all` row
per non-`$all` row, then:

```sql
UPDATE streams SET stream_version = (select max(stream_version) from stream_events where stream_id='$all')
where stream_id = '$all'
```

Three problems:

1. **The high-water mark is one too low.** `insert_in_stream/3` uses
   `streams.stream_version` as the *next* position. After the rebuild it holds the
   *last* position used, so the next append writes `$all` at that position again
   and fails on the unique index `(stream_id, stream_version)`. The whole append
   rolls back, so every append fails until someone fixes the row by hand.
2. **A missing `$all` row isn't created.** On a store that has never had `$all`
   (the case "initial fill" exists for), the `UPDATE` matches nothing. The next
   append then creates the row with `stream_version = 0` and collides with
   position 0.
3. **Positions have gaps.** Each `$all` position is the old `stream_events.id` of
   the source row. Those ids are interleaved with the deleted `$all` rows' ids, so
   a rebuilt `$all` has gaps even if nothing was ever archived. Gaps are harmless
   for reads (see 0005), but there's no reason for a rebuild to create them.

A side note for 0005: the rebuild copies every non-`$all` row, so once
`$archives` exists it would be copied into `$all` too.

Also, the empty store: `max(...)` over no rows is NULL, and
`streams.stream_version` is `NOT NULL`, so a rebuild of an empty store with a
`$all` row fails.

## Proposed change

The rebuild already renumbers `$all` and invalidates every subscriber's saved
`$all` position. Given that, number it densely and in append order:

```sql
DELETE FROM stream_events WHERE stream_id = '$all';

INSERT INTO stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version)
SELECT event_id, '$all', row_number() OVER (ORDER BY id) - 1, stream_id, stream_version
FROM stream_events
WHERE stream_id NOT IN (…system streams…)
ORDER BY id;

INSERT INTO streams (stream_id, stream_version, inserted_at)
VALUES ('$all', (SELECT count(*) FROM stream_events WHERE stream_id = '$all'), …)
ON CONFLICT (stream_id) DO UPDATE SET stream_version = excluded.stream_version;
```

- Positions are `0..n-1` in `stream_events.id` order, the order the events were
  appended in. The old code ordered rows by `event_id` but numbered them by
  `id`. With caller-supplied (non-UUIDv7) ids those orders differ (see 0003).
- The high-water mark is the count, which is the next free position, and 0 for an
  empty store.
- The `$all` row is created if it's missing.
- The system streams (`$all`, and `$archives` from 0005) come from the same module
  attribute as the append refusal in 0004.
- `row_number()` needs SQLite ≥ 3.25.

The `@doc` says, in so many words, that a rebuild renumbers `$all`, that every
saved `$all` position is invalid afterwards, and that `$all` subscribers have to
start over.

## Tests

- Rebuild, then append: the append succeeds and gets position `n`.
- Rebuild a store with no `$all` row: the row is created, and an append succeeds.
- Rebuild an empty store: succeeds, high-water mark 0.
- Positions after a rebuild are exactly `0..n-1`, in append order, with the
  origin columns filled.
- After 0005: rebuild after an archive. Neither `$archives` nor archived events
  are in `$all`, and an append afterwards succeeds.
