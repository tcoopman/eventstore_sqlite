# Issue — every read sorts the whole remaining stream, so reads get slower as a stream grows

- **Status:** Single-stream reads fixed (fix A). Multi-stream reads are still open
  (noted 2026-09-28). Benchmarked on `bench.db`, before → after: read 10 events
  252 ms → 0.08 ms, read backward 10 415 ms → 0.08 ms, read forward/backward 10 000
  2.6 s / 8.9 s → 41 / 42 ms, fold of 30 000 events 7.6 s → 141 ms, memory
  unchanged. Two-stream read of 10 is unchanged at ~635 ms. No local store
  (bench/dev/test) has `stream_version` and `id` in different orders; run the check
  under "Open points" on tickets-admin prod before deploying.
- **Found via:** benchmarking the `:chunk_size` / catch-up changes (issue 0002)
  against `bench.db`.

## Symptom

Read time depends on the size of the stream, not on how much you read. On
`bench.db` (stream `test` with 696 585 events, `$all` the same size),
`bench/eventstore.exs`-style reads take:

| read | time |
|---|---|
| `read_stream_forward("test", count: 10)` | ~250 ms |
| `read_stream_forward("test", count: 100)` | ~255 ms |
| `read_stream_backward("test", count: 10)` | ~420 ms |
| `read_stream_backward("test", count: 100)` | ~800 ms |
| `read_stream_forward("test", count: 10_000)` | ~2.6 s |
| `read_stream_backward("test", count: 10_000)` | ~8.7 s |

Reading 10 events should take well under a millisecond.

## Cause

`Reader.fetch_chunk/4` generates, for a single stream:

```sql
SELECT … FROM stream_events AS s0
INNER JOIN events AS e1 ON s0.event_id = e1.id
WHERE ((s0.stream_id = ?) AND (s0.stream_version >= ?))
ORDER BY s0.id
LIMIT ?
```

`EXPLAIN QUERY PLAN`:

```
|--SEARCH s0 USING INDEX stream_events_stream_id_stream_version_index (stream_id=? AND stream_version>?)
|--SEARCH e1 USING INDEX events_id_index (id=?)
`--USE TEMP B-TREE FOR ORDER BY
```

The only `stream_events` index is `(stream_id, stream_version)`, and the query
orders by `id`. So SQLite finds every row of the stream from the start version
on, joins each one to `events`, reading its `data` blob, sorts them all by `id`,
and only then applies `LIMIT`.

`Reader.stream/4` fetches each chunk with a separate query (`s0.id > cursor`), and
every chunk sorts all rows after the start version again. Reading a whole stream
therefore costs roughly `rows × chunks`, quadratic in stream length. That is why
`count: 10_000` (ten 1 000-row chunks) takes about ten times as long as `count: 10`.
Backward reads are slower because the rows past the cursor are the whole front of
the stream.

The same query runs for subscriptions (`read_stream_forward` per catch-up batch)
and for folds via `stream_forward`, so both get slower as the stream grows too.

## Measured fixes (on a copy of `bench.db`, `sqlite3` with `.timer on`)

### A. Single stream: order and paginate by `stream_version` (no schema change)

Within one stream, `stream_version` is assigned in insert order, so it follows the
same order as `id`. With `ORDER BY s0.stream_version`, the existing index returns
the rows already sorted and SQLite stops at the `LIMIT`:

```
|--SEARCH s0 USING INDEX stream_events_stream_id_stream_version_index (stream_id=? AND stream_version>?)
`--SEARCH e1 USING INDEX events_id_index (id=?)
```

| query | now | ordered by version |
|---|---|---|
| asc 10 | 249 ms | < 1 ms |
| desc 10 | 364 ms | < 1 ms |
| desc 1 000 | — | 1.3 ms |
| asc 10 000 | — | 7.8 ms |
| asc 1 000 from version 600 000 | 161 ms (id cursor) | < 1 ms |

The chunk cursor becomes the last `stream_version` (`>` for asc, `<` for desc)
instead of `stream_events.id`.

### B. Add an index on `(stream_id, id)` and `ANALYZE`

The index alone does nothing: the planner keeps picking the version index and
sorting. After `ANALYZE` it uses the new index for a plain single-stream read
(< 1 ms), but:

- with a start version above 0 it goes back to the version index and sorts;
- a read of two streams becomes `SCAN s0`, a full table scan in `id` order;
- it depends on statistics that existing databases don't have, and on a
  migration that has to build an index over all of `stream_events`.

**Recommendation: A.** It needs no migration and doesn't depend on the planner.

## Open points

- **Multi-stream reads** (`stream_forward(["a", "b"])`) still need `id` order to
  interleave streams, and the `OR` of per-stream conditions still sorts. Option:
  one sub-select per stream, each ordered by `stream_version` with the chunk
  `LIMIT` (each uses the index), combined with `UNION ALL` and ordered by `id`
  with the same `LIMIT`. The cursor then becomes a per-stream map of the last
  version seen. Could be a follow-up; single-stream reads are the common case.
- **`$all` filled by `Migration.intial_fill_all/0`** sets `stream_version` to
  the old `stream_events.id` but inserts rows ordered by `event_id`. If those two
  orders ever differed, reading `$all` by version would give a different order
  from reading it by `id` today. Check that version and `id` order agree on
  existing stores (e.g. tickets-admin prod) before switching:
  `select count(*) from stream_events a join stream_events b on a.stream_id = b.stream_id and a.stream_version < b.stream_version and a.id > b.id`
  should be 0. Run it per stream if it's too slow.
- Worth adding a benchmark for a whole-stream `stream_forward` fold, which is
  quadratic today.

## Tests

- Existing reader tests (asc/desc, chunk boundaries, start versions, `count`,
  multi-stream) must keep passing unchanged, since the order must not change.
- A regression test that a single-stream read's query plan has no
  `TEMP B-TREE`, via `EXPLAIN QUERY PLAN` on the SQL from
  `Ecto.Adapters.SQL.to_sql/3`, so a later query change can't bring the sort back.
