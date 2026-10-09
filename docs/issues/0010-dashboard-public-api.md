# Issue — live_eventstore reads the database behind the public API

- **Status:** Done 2026-10-09: `stream_info/1`, `list_stream_infos/1`,
  `subscribe_to_changes/1`, and the `Sync.status/0` additions. The dashboard
  uses only the public API; `LiveEventstore.Overview` is gone. Quarantine
  paging is left open (see "Not done").
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
4. **Ownership:** active assignments.
5. **Change log:** what this node retains that a peer hasn't acknowledged yet,
   and why it can't be pruned.
6. **History:** recent sync and ownership events: enabled, peers added and
   removed, halts and resumes, assignments, releases, revokes.

## What the public API covered

| Need | Public API | Verdict |
|---|---|---|
| Stream names | `list_streams/0` | Every name, unpaged. Fine at 1 000 streams, not at 100 000. No metadata. |
| Stream metadata | none | Missing. `read_stream_backward(id, count: 1)` gives the last event, not the created time, and decodes event data. |
| Node and peers | `Sync.status/0` | Mostly covered (see 2 below). |
| Owner of a stream | `Ownership.owner/1` | Covered for one stream; each call loads the sync state. |
| Active assignments | `Ownership.list/0` | Covered. |
| Quarantine | `Sync.quarantine/0` | Covered, but returns every entry with its payload. |
| History | `read_stream_backward("$sync")`, `read_stream_backward("$ownership")` | Works today. The `EventstoreSqlite.SystemEvents` structs are public, but reading these streams isn't documented as supported. |
| Knowing when to refresh | `subscribe_to_stream("$all")` | Too heavy: delivers every event with its data. |

## Decisions

- **Search anywhere in the name, not by prefix.** Stream names can be
  anything; `category:id` is only a convention, so the API doesn't assume it.
  A search scans the stream names, which is documented.
- **Ordered by name only, paged by name.** No sort by version or time, and no
  total: those need extra indexes or a scan, and the dashboard doesn't need
  them. `:after` takes the last name of the previous page, so a stream created
  while paging doesn't shift the pages.
- **`StreamInfo` is a struct**, like `RecordedEvent`.
- **`StreamInfo` carries the owner** when sync is enabled. One sync state read
  per call, so a page of 50 costs no more than one stream.
- **The change message says what changed** (`:streams`, `:sync`), so a view
  can skip `Sync.status/0`, and its call to every replicator, when only
  streams changed.
- **No store totals** (stream count, event total, `$all` position, archived
  count). They were nice, not useful.

## What was built

### Stream metadata

```elixir
EventstoreSqlite.stream_info("orders:1001")
#=> {:ok, %EventstoreSqlite.StreamInfo{stream_id: "orders:1001", version: 12,
#=>   created_at: ~U[...], last_event_at: ~U[...], owner: {"main-node", 0}}}

EventstoreSqlite.list_stream_infos(search: "1001", limit: 50, after: "orders:0999")
#=> %{entries: [%StreamInfo{}, ...], next: "orders:1050" | nil}
```

`version` means what `{:version, n}` means for `append_to_stream/3`.
`created_at` and `last_event_at` are the first and last events' own
timestamps, so they are the same on every node; the `streams` row's own
`inserted_at` is local to the node and isn't used.

### Change notification

```elixir
:ok = EventstoreSqlite.subscribe_to_changes(self())
# {:eventstore_sqlite, :changed, [:streams]}
# {:eventstore_sqlite, :changed, [:streams, :sync]}
```

`EventstoreSqlite.Changes` holds the subscribers. The first change goes out at
once; changes during the next interval (1 s) are sent together when it ends.
It is notified after:

- an append or archive commits (`:streams`, plus `:sync` when sync is
  enabled, because the change log grew);
- an import from a peer commits (`:streams`, `:sync`), or only the peer's
  reported head changed (`:sync`);
- a sync state change (`:streams`, `:sync`: ownership changes owners);
- a replicator's connection or last error changes (`:sync`);
- a peer's acknowledgement advances, which can prune the log (`:sync`).

A write from another BEAM on the same file isn't seen, so the dashboard also
reloads every 30 s.

### `Sync.status/0`

- `log: %{oldest, entries}` — the entries retained for peers. Pruning only
  removes a prefix, so `entries` is `head - oldest + 1` and costs no count.
- per peer `last_applied_at` — a new `applied_at` column in `sync_cursors`
  (migration `20261010120000`), set when the cursor moves forward. With `lag`
  above 0, an old value means replication is stuck rather than busy.
- The documentation lists every field, including `:busy` and `:not_running`,
  and that `last_success` and `last_error` are lost on restart.

### History

`"$sync"` and `"$ownership"` are read with `read_stream_backward/2`, as
before; the dashboard shows the latest 15 of both.

## Corrections to the first version of this proposal

- **"A pending snapshot isn't in `status/0`."** `state.snapshot` only exists in
  the snapshot copy, before the new node claims it. On the home node a peer
  that hasn't claimed its snapshot yet is a peer with `peer_head: nil`, which
  `status/0` already shows.
- **"Handovers in progress aren't in `Ownership.list/0`."** On the home node a
  generation stays active until it has pulled the release, which is correct:
  it doesn't write those streams until then. On the owner it moves to
  `released` at once. `state.released` is history, not work in progress; the
  history panel shows it.
- **`Ownership.owners/1`** isn't needed: the owner is in `StreamInfo`.

## Not done

- **Quarantine paging.** `Sync.quarantine/0` still returns every entry with
  its payload. The dashboard shows only the count per peer, from
  `Sync.status/0`.
- **Documenting `"$sync"` and `"$ownership"` as public reads.** They work
  with `read_stream_backward/2`, and the dashboard relies on that, but the
  `SystemEvents` structs aren't yet documented as a stable contract.
- **`Sync.verify/2` from the dashboard.** It compares whole histories over
  distribution; it stays an iex tool.
