# Issue — let callers set the read chunk size on `stream_forward` / `stream_backward`

- **Status:** Done (noted 2026-09-28, built in 0511106a "more options on chunk sizes").
  Also in that change: `stream_*` no longer stops at 10 000 events by default, appends of
  more than 6 553 events no longer fail, and subscriptions catch up in batches
  (`subscribe_to_stream/5`, `batch_size:`). The ~156 MB peak at `chunk_size: 1` from
  PRD-0017 is still to be measured against tickets-admin's data.
- **Found via:** tickets-admin PRD-0017 (observation-log fold OOM), R1.

## Problem

`stream_forward/2` and `stream_backward/2` always read in chunks of
`@default_chunk_size` = 1000 rows (`lib/eventstore_sqlite.ex`), and callers can't
change that. `Reader.stream/4` fetches a whole chunk of raw rows in one query and
keeps them all in memory until the consumer has worked through that chunk. The
per-row `RecordedEvent.parse/1` is lazy, but the raw `data` binaries are not.

This matters for streams of large events. tickets-admin's `tito-observations` has
139 events totalling 100 MB, about 0.72 MB on average and up to about 7 MB each. So
one chunk is the entire stream, and a caller that folds the stream one event at a
time still holds about 100 MB of raw rows for the whole fold. Past 1000 events, a
full chunk would be about 720 MB in one query result.

## Measured

A tickets-admin streamed fold (`stream_forward |> Enum.reduce`, projecting each
event to a small struct) on a copy of its `dev.db`. The 114-event case is the same
log with every event linked twice. The figures are peak `:erlang.memory(:total)`
above baseline:

| chunk size | 57 events (63 MB) | 114 events (126 MB) |
|---|---|---|
| 1000 (current, fixed) | +260 MB | +362 MB |
| 20 | +202 MB | — |
| 5 | +157 MB | +181 MB |
| 1 | +156 MB | +156 MB |

With small chunks the peak doesn't depend on stream length. Wall time was the same
for 1, 5 and 20 (about 0.9 s for 57 events, about 2 s for 114). These numbers were
measured by calling `EventstoreSqlite.Reader.stream/4` directly, which is
`@moduledoc false`, so callers shouldn't have to.

## Proposed change

Accept a `:chunk_size` option next to `:count` in every `stream_forward/2` and
`stream_backward/2` clause, defaulting to `@default_chunk_size`:

```elixir
def stream_forward(stream_id, opts) when is_binary(stream_id) do
  limit = Keyword.get(opts, :count, @default_count)
  chunk_size = Keyword.get(opts, :chunk_size, @default_chunk_size)

  Reader.stream([{stream_id, 0}], :asc, chunk_size, limit)
end
```

Also:

- Pass it through `read_stream_forward/2` and `read_stream_backward/2` (they already
  forward `opts`).
- Document both `:count` and `:chunk_size` on `stream_forward`/`stream_backward`.
  The **silent 10 000-event default `:count`** deserves a mention: a caller folding a
  whole stream truncates without any error once the stream passes 10 000 events
  (PRD-0017 R3).
- Tests: a small `chunk_size` (e.g. 2 over 5 events) returns every event in order,
  forward and backward, including when combined with `:count` and a start version.
  `Reader.stream/4` guards `chunk_size > 0`, so an invalid value already fails
  loudly.

## Consumer side (tickets-admin, after bumping the dependency)

- `TicketsAdmin.EventStore.stream_forward/2` passes `opts` through.
- `Store.fold_log/0` reads `tito-observations` with something like
  `chunk_size: 5` and an explicit `count:`.
