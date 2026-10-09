# Issue — live_eventstore reads the database behind the public API

- **Status:** Proposal, 2026-10-09. Nothing built.
- **Found via:** a review of the live_eventstore dashboard (a9ad1b9): about one
  query per second per open tab, and SQL in `LiveEventstore.Overview` that no
  application can use.

## Problem

`EventstoreSqlite.LiveEventstore.Overview` queries `streams`, `stream_events`,
`events`, `archived_streams` and `sync_state` directly with SQL. The dashboard
can show things an application can't ask for, and `Overview` is a documented
module (`@moduledoc`, `@doc`) that is half a public API without having been
designed as one.

It also polls: every open tab reloads every 5 seconds with six queries, because
nothing tells it the store changed.

## Rule

The dashboard only uses the public API. Anything it needs that the public API
lacks is added to the public API, designed for applications first. `Overview`
goes away, or becomes `@moduledoc false` glue with no SQL in it.

## What the dashboard should show

The current summary cards (live stream count, event total, `$all` position,
archived stream count) are nice to have but not useful, and aren't worth public
API. They are dropped. Sync is where an operator needs insight.

1. **Streams:** name, version, created, last event, owner. Searchable and paged.
2. **This node:** node id, home or peer, enabled, diverged.
3. **Per peer:** connection, lag, last success and last error, halted reason,
   quarantined entries, generations owned.
4. **Ownership:** active assignments, and handovers in progress.
5. **Change log:** what this node retains that a peer hasn't acknowledged yet,
   and why it can't be pruned.
6. **History:** recent sync and ownership events: enabled, peers added and
   removed, halts and resumes, assignments, releases, revokes.

## What the public API covers today

| Need | Public API | Verdict |
|---|---|---|
| Stream names | `list_streams/0` | Every name, unpaged. Fine at 1 000 streams, not at 100 000. No metadata. |
| Stream metadata | none | Missing. `read_stream_backward(id, count: 1)` gives the last event, not the created time, and decodes event data. |
| Node and peers | `Sync.status/0` | Mostly covered (see 2 below). |
| Owner of a stream | `Ownership.owner/1` | Covered for one stream; each call loads the sync state. |
| Active assignments | `Ownership.list/0` | Covered. Handovers in progress (released, not yet pulled) aren't shown. |
| Quarantine | `Sync.quarantine/0` | Covered, but returns every entry with its payload. |
| History | `read_stream_backward("$sync")`, `read_stream_backward("$ownership")` | Works today. The `EventstoreSqlite.SystemEvents` structs are public, but reading these streams isn't documented as supported. |
| Knowing when to refresh | `subscribe_to_stream("$all")` | Too heavy: delivers every event with its data. |

## Proposed API

### 1. Stream metadata

```elixir
EventstoreSqlite.stream_info("orders:1001")
#=> {:ok, %EventstoreSqlite.StreamInfo{
#=>   stream_id: "orders:1001",
#=>   version: 12,
#=>   created_at: ~U[...],
#=>   last_event_at: ~U[...]
#=> }}
#=> {:error, :not_found}
```

`version` means the same as in `{:version, n}` for `append_to_stream/3`: the
next version, which is also the event count. `created_at` is when the stream's
first event was appended; after an archive and a new first append, it is the
new incarnation's. It works for system streams too.

A paged listing returning the same structs:

```elixir
EventstoreSqlite.list_stream_infos(prefix: "orders:", limit: 50, after: "orders:1050")
#=> %{entries: [%StreamInfo{}, ...], next: "orders:1100" | nil}
```

Options:

- `:prefix` — only names starting with this text. A prefix uses the primary
  key index, and matches how stream names are usually built (a category, then
  an id) and how ownership selectors work (`"venue:*"`).
- `:limit` — default 100.
- `:after` — a stream name; the page starts after it. Keyset paging by name
  stays cheap and stable while streams are created; offsets do neither.
- `:system` — include system streams (default `false`).

`list_streams/0` stays as it is.

The dashboard loses three things it has today, all deliberately:

- **Substring search.** It becomes prefix search. Substring search is a full
  scan, which the dashboard can afford and an application API shouldn't
  promise.
- **Sorting by events or created.** That needs an index per sort column, or a
  scan.
- **"Page x of y" and the total.** Keyset paging has a next page and no total.

See open question 1.

### 2. Sync status: what's missing from `Sync.status/0`

`Sync.status/0` already returns the node, peers, connection, lag, acks, halts,
quarantine counts, owned generations, last error and last success. What it
lacks:

- **A pending snapshot.** `state.snapshot` (created, not yet claimed by the new
  peer) isn't returned. Add `snapshot: %{peer, snapshot_id, head_seq,
  created_at} | nil`.
- **The change log.** Add `log: %{head, oldest, entries}`. `oldest` is the
  oldest seq still retained. Together with each peer's `acked` and
  `pinned_seq`, which are already returned, this answers "why isn't the log
  shrinking": a peer hasn't acknowledged, or a snapshot pins it.
- **Lag in time, not just entries.** `lag` counts entries, and 3 entries
  behind can mean 3 milliseconds or 3 hours. Add `last_applied_at`: when this
  node applied the last entry from that peer. It needs a column in
  `sync_cursors`, so it survives a restart, unlike `last_success`, which is
  replicator memory.
- **Timestamp types.** `last_success` and `last_error` come from the
  replicator's memory and are lost on restart. Document that, and return
  `DateTime`s everywhere.

`Sync.status/0` makes one GenServer call per peer (1 s timeout). That is fine
for a refresh triggered by a change, but it means a hung replicator delays the
dashboard by a second per peer. The result already says `:busy`, so this only
needs documenting.

### 3. Ownership

- **`Ownership.owners(stream_ids)`** returns `%{stream_id => {node_id,
  generation}}` with one state load, for a page of streams. The dashboard can't
  match `Ownership.list/0` selectors itself: the matching rules live in
  `Sync.Selector`, which is internal, and copying them would let the dashboard
  disagree with the write path.
- **Handovers in progress.** `Ownership.list/0` shows active assignments only.
  A generation that has been released but not yet pulled by the home node is
  invisible, which is exactly the moment an operator watches. Add `state:
  :active | :released` to each entry, with the `release_seq` for released
  ones. Revoked generations stay out of the list; they show up in history.

### 4. Quarantine

`Sync.quarantine/0` decodes and returns every entry with its payload. Add
`Sync.quarantine(limit: 20)`, newest first, or a variant without `entry`, so a
dashboard can show the latest few without loading them all. The count per peer
is already in `Sync.status/0`.

### 5. History

Document `"$sync"` and `"$ownership"` as readable with `read_stream_backward/2`,
returning `EventstoreSqlite.SystemEvents` structs. This makes those structs
contract: renaming a field needs an upcaster, like any application event. That
is already true in practice, because they're stored as events.

### 6. Change notification

```elixir
:ok = EventstoreSqlite.subscribe_to_changes(self())
# receives {:eventstore_sqlite, :changed} at most once per interval
```

The message carries nothing and is coalesced per subscriber (default: at most
one per second). It is sent after:

- an append or archive commits, locally or applied from a peer;
- a sync state change, such as an assignment, release, halt or divergence;
- a replicator connecting or disconnecting.

Like subscriptions, it is local to this node and best-effort: a write from
another BEAM on the same SQLite file sends nothing. The dashboard keeps a slow
fallback poll (30–60 s) for that.

Telemetry already reports halts, divergence, quarantine, imports and lag, but a
telemetry handler runs in the emitting process and is global, so it doesn't fit
a LiveView. This message is the process-level counterpart.

## Not proposed

- **Store totals** (stream count, event total, archived count, `$all`
  position). The dashboard drops them. If they come back, they should be a
  separate `stats/0` designed for its cost: the event total sums every stream's
  version.
- **Reading archived streams.** Still no public API, as documented in
  `EventstoreSqlite`.
- **Calling `Sync.verify/2` from the dashboard.** It's public, but it compares
  whole histories over distribution. A dashboard button would make an
  expensive operation one click away. Leave it in iex.

## Open questions

1. Is losing substring search, the sort by events or created, and the total
   acceptable? The alternative is a `:search` option documented as a full scan,
   and indexes on `streams(stream_version)` and `streams(inserted_at)` for
   sorting. Sorting by last event, which is the most useful ("what's busy
   now"), needs a `last_event_at` column on `streams`, maintained on append.
2. `StreamInfo` struct or a plain map? `RecordedEvent` is a struct, so a struct
   matches.
3. Should `subscribe_to_changes/1` say what changed (`:streams`, `:sync`)? It
   would let the dashboard skip `Sync.status/0` (and its GenServer calls) when
   only streams changed. Cheap to add now, awkward to add later.
4. Should owners be part of `StreamInfo` when sync is enabled? It saves the
   dashboard a call, but makes stream metadata depend on sync.

## Order of work

1. `stream_info/1`, `list_stream_infos/1`, `Ownership.owners/1`. The dashboard
   moves off SQL for the streams table.
2. `Sync.status/0` additions and `Ownership.list/0` states. The dashboard gets
   sync cards in place of the totals.
3. `subscribe_to_changes/1`. The dashboard stops polling.
4. Quarantine paging and documenting history, with a history panel.
