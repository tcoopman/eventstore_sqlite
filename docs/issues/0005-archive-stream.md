# Issue — archive a whole stream so the live store looks as if it never existed

- **Status:** Done 2026-10-02 (archive streams). Builds on 0004 and 0006. On a copy of
  `bench.db`, archiving the 696 585-event stream `test` takes 2.9 s; the race
  test archives in the middle of 40 concurrent appends (13–16 land in the
  archive, the rest in the new stream).
- **Found via:** resetting test data (rehearsing a stream such as `ada` from
  scratch). May later become a real user-facing feature, so the design must not
  rule out unarchiving.

## Goal

`EventstoreSqlite.archive_stream(stream_id)` archives a whole stream in one
transaction. Afterwards, every public API behaves as if the stream never existed:

- `list_streams`, `stream_forward` / `stream_backward` / `read_*` and `$all` don't
  return it;
- subscriptions don't see it;
- the name is free again: `append_to_stream("ada", events, :no_stream)` succeeds
  and starts at version 0.

The data isn't destroyed. It stays in the database and can be inspected with SQL,
and a later unarchive stays possible.

Only whole streams can be archived.

## API

```elixir
archive_stream(stream_id, expected_version \\ :any_version)
  :: :ok | {:error, :stream_not_found | :wrong_expected_version | :system_stream}
```

- `expected_version` is the same as for `append_to_stream`, so the caller can avoid
  archiving an event they haven't seen yet.
- `"$all"` and `"$archives"` are refused with `{:error, :system_stream}`.
- Archiving a stream that doesn't exist (or is already archived) returns
  `{:error, :stream_not_found}`.

## Storage

Two new tables. The rows are moved out of the live tables, not flagged in place:

```
archived_streams(id, stream_id, stream_version, created_at, archived_at)
archived_stream_events(archive_id, event_id, stream_version, all_position)
```

- `archived_streams.id` identifies one archive. A name can be archived, reused and
  archived again, so the name alone isn't a key.
- `stream_version` and `created_at` are copied from the `streams` row.
- `all_position` is the event's old position in `$all`, kept for inspection and a
  later unarchive.

Moving the rows (instead of an `archived_at` column on `stream_events`) means the
live tables only ever hold live data. `Reader`, `list_streams`,
`validate_version` and `Subscriptions` don't change, and no query can forget a
filter and leak archived events. It also keeps the unique index on
`stream_events (stream_id, stream_version)` as it is, which is what makes the
name reusable.

## The archive transaction

One `:immediate` write transaction, like an append:

1. Check `expected_version` and that the stream exists.
2. Insert the `archived_streams` row.
3. `INSERT INTO archived_stream_events … SELECT` the stream's rows, joined to their
   `$all` rows (via `original_stream_id` / `original_stream_version` from 0004) to
   get `all_position`.
4. **Check the counts.** The stream's `streams.stream_version`, the number of its
   rows in `stream_events`, the number of rows just copied into
   `archived_stream_events` (each with a non-NULL `all_position`), and the number
   of `$all` rows whose origin is this stream must all be equal. Normal appends
   keep each stream row paired with exactly one `$all` row. If that pairing is
   broken, the join in step 3 would silently drop an event (no `$all` row) or copy
   it twice (two `$all` rows), and step 4 would then delete it from the live
   tables anyway. On any mismatch the transaction raises and rolls back, with a
   message giving the four numbers, so nothing is archived from a stream that
   can't be archived completely.
5. Delete the stream's `$all` rows and its own rows from `stream_events`.
6. Delete the `streams` row. This must come after step 5, because `stream_events`
   has foreign keys to `streams.stream_id`.
7. Append a `SystemEvents.StreamArchived` event to `$archives` (see below).

The `events` table is never touched. The existing `no_delete_events` trigger
already guarantees that.

Everything happens in SQL (`INSERT … SELECT`, `DELETE … WHERE`), so archiving a
large stream doesn't load its events into Elixir.

## `$all` gets gaps

The archived events' `$all` positions disappear and are never reused or
renumbered. Renumbering would invalidate every subscriber's saved `$all`
position.

What this relies on: the `$all` row's `streams.stream_version` is the next free
position (a high-water mark), not a count of `$all` events. `insert_in_stream`
already uses it as the next index. Archiving must never lower it, or the next
append would reuse an old position and hit the unique index.

Reads and subscriptions already work with gaps: `Reader` filters with
`>= start_version` and pages with `> cursor`, and `Subscriptions` moves on to the
last delivered `stream_version + 1`.

## `$archives` system stream

Each archive appends one event to the stream `$archives`:

```elixir
%EventstoreSqlite.SystemEvents.StreamArchived{stream_id: "ada", archive_id: 7, event_count: 12}
```

- `event_count` is the stream's `streams.stream_version` at the moment it was
  archived: the number of archived events, which is also the version the next
  event would have had. Versions are zero-based, so the archived events are
  versions `0..event_count - 1` (here 0–11). It is not the last event's version.
- `archive_id` is the `archived_streams.id` of this archive.

### Namespacing system events

Events written by eventstore_sqlite itself live under
`EventstoreSqlite.SystemEvents.*`. Their stored `type` is the module name
(`Atom.to_string(event.__struct__)` in `Event.build/3`), so the namespace keeps
them apart from an application's or another library's own `StreamArchived`.
This applies to every system event from now on (a later `StreamUnarchived`
included). Consumers must not define modules in that namespace; the
`SystemEvents` moduledoc says so.

Payloads are stored with `:erlang.term_to_binary/1`, so a system event's
struct may only gain fields, never lose or rename them, and readers must accept
old events that lack a newer field.

- It gives an audit trail of what was archived and when.
- It lets projections built from `$all` react to an archive: subscribe to
  `$archives` and drop that stream's data. Thanks to 0004, they can tell which of
  their events came from that stream.
- `$archives` events are **not** written to `$all`. If they were, `$all` would
  record a stream that, from `$all`'s point of view, never existed, and a
  projection rebuilt later would see an archive event for a stream it never saw.
- `$archives` is a normal, visible stream: it appears in `list_streams` (like
  `$all` does) and can be read and subscribed to.
- `append_to_stream("$archives", events)` returns `{:error, :system_stream}`, as
  `$all` does from 0004. The archive transaction writes the `StreamArchived` event
  through an internal function that doesn't go through `append_to_stream` and
  doesn't write a `$all` row.
- The stream is created on the first archive, so stores that never archive don't
  have it.

### The name `$archives` may already be taken

Today any name can be appended to, so a store may already have a user stream
called `$archives`. If so, the first archive would append system events to that
user's stream, and the new append refusal would suddenly lock its owner out.
eventstore_sqlite must never silently take over an existing stream.

The migration that adds the archive tables therefore checks for a `streams` row
or `stream_events` rows with `stream_id = '$archives'` and, if there are any,
aborts with an actionable error, for example:

> A stream named "$archives" already exists (N events). eventstore_sqlite now
> reserves this name for its archive log. Copy its events to a stream with
> another name and remove it, then run the migration again.

After the migration has run, `append_to_stream` refuses the name, so a collision
can't appear later. `$all` needs no check here: user events can only have got
into it through a direct append, and those rows have no original stream, so the
0004 migration, which runs first, already aborts on them.

The check runs in the migration rather than at `archive_stream` time, so the
problem appears when upgrading, where someone is watching, and not on the
first archive in production.

## Subscriptions

**Subscribers to the archived stream** receive

```elixir
{:stream_archived, "ada"}
```

and their subscription ends. The docs for `subscribe_to_stream` and
`archive_stream` say that a subscriber who wants the stream's new events must
subscribe again.

**`$all` subscribers** get no message. Catching-up subscribers simply never see
the archived events. Subscribers that already processed them must learn about it
from `$archives`. Projections built at different times can therefore disagree
until they handle `$archives`, and this needs to be documented.

### Why this can't be left alone: stale cursors

`Subscriptions` keeps a read cursor per stream (`subscribed_streams["ada"]`) and
a version per subscriber. If `ada` was archived at version 12 and the cursor
isn't reset, the new `ada`'s events 0–11 are skipped without any error, and
event 12 onwards is delivered to subscribers of the old `ada`.

### Race between the archive and the next append

Notifying `Subscriptions` with a cast after the commit (as `ping` does) isn't
enough. Between the commit and the cast, another process can append to the new
`ada` and send its `ping`. Casts from different processes have no guaranteed
order, so `Subscriptions` could serve the ping with the old cursor first.

Fix: run the archive **through the `Subscriptions` GenServer**, as a
`GenServer.call` that runs the transaction and then, in the same callback,
after the commit:

1. removes the stream's subscribers, sends them `{:stream_archived, stream_id}`,
   and drops `subscribed_streams[stream_id]`;
2. queues `$archives` in `streams_to_handle` (as `ping` does for a stream), and
   replies with `{:continue, :handle_stream}`, so `$archives` subscribers receive
   the new `StreamArchived` event right away instead of on some later ping.
   `$all` doesn't need to be queued: the archive adds nothing to it.

Any ping for the new `ada` is handled after that. If the transaction fails,
nothing is reset or queued. The cost is that subscriptions are not served while
an archive transaction runs, which is acceptable for an occasional operation.

## Not in v1, but kept possible

- **Unarchive.** Everything it needs is kept: the events, each event's stream
  version and old `$all` position, and the stream's `created_at`. Proposed
  semantics for later:
  - only allowed when the name is free;
  - the stream gets its original versions back;
  - the events get **new** `$all` positions at the end, not their old gaps.
    Subscribers already past those positions would otherwise never see them.
  - a `SystemEvents.StreamUnarchived` event is appended to `$archives`.
- **Inspection API** (`list_archived_streams/0`, `read_archived_stream/1`). For now
  the archive tables can be queried with SQL.

## Known leaks of "as if it never existed"

- Archived events keep their ids in `events`. Appending an event with a
  caller-supplied id equal to an archived event's id still fails as a duplicate.
  This is acceptable with UUIDs and will be documented.
- `$all` positions have gaps.

## Backward compatibility

Nothing changes for a store that never calls `archive_stream`:

- The migration only adds tables. Code built before this change ignores them.
- Archiving adds no gaps to `$all`, `list_streams` doesn't list `$archives`, and
  no subscriber ever receives `{:stream_archived, _}`. (`$all` can already have
  gaps today if it was rebuilt with the old `intial_fill_all/0`. 0006 makes
  rebuilds gap-free.)

**Rolling back the library:**

- **Before the first archive:** safe. The new tables are empty and ignored, and
  the migration's `down` drops them.
- **The migration's `down` refuses once anything is archived,** because dropping
  the archive tables would lose which stream and versions the archived events
  belonged to. (Raised in the gpt-luna review.)
- **After an archive: not supported.** An older version can't see the archive
  tables. The archived events seem to have disappeared, `$archives` is an ordinary
  stream it will let anyone append to, and nothing stops it from appending
  `StreamArchived` structs it can't decode. Reused names keep working, but the
  older version has no idea they were ever archived. The `@doc` of `archive_stream`
  and the changelog state this. Recovering would mean hand-written SQL that
  copies `archived_stream_events` back into `stream_events`, which is unarchive
  without the API, so the advice is to not roll back.

Once a store does archive, document the visible changes for consumers:

- `$all` positions can have gaps. Code that expects `position == last + 1`, or that
  `$all`'s `stream_version` equals its event count, must stop relying on it.
- `list_streams` can include `$archives`.
- Subscriber processes must handle `{:stream_archived, stream_id}`. A GenServer
  with a strict `handle_info` would crash on it. One without a catch-all clause
  logs it as an unexpected message.

## Open points

- **The `$all` rebuild** (`Migration.intial_fill_all/0`) must skip `$archives`.
  Archived streams are already safe, because their rows are no longer in
  `stream_events`. This, the high-water-mark bug and the gaps the rebuild creates
  are in 0006, which must land first.
- `append_to_stream` refuses only `$all` and `$archives`, not every `$`-prefixed
  name, because that would break anyone already using `$` names. If more system
  streams are added later, it may be worth reserving the whole `$` prefix in a
  major version.

## Tests

- After an archive: `read_stream_forward("ada")`, `stream_backward`, multi-stream
  reads that include `ada`, `$all` reads and `list_streams` don't show it;
  `append_to_stream("ada", events, :no_stream)` succeeds at version 0.
- The archive tables hold every event with its version and old `$all` position.
  The `events` rows still exist.
- `$all` keeps its high-water mark: the next append after an archive gets the
  next position, not a reused one.
- Archive, reuse the name, archive again: two archives, both complete.
- `expected_version` mismatch, a missing stream, and `$all` / `$archives` are
  refused, and nothing is written.
- `$archives` contains `StreamArchived` with the right `archive_id` and
  `event_count`, its stored type is
  `Elixir.EventstoreSqlite.SystemEvents.StreamArchived`, and it isn't in `$all`.
- A subscriber of `$archives` (subscribed before the archive) receives the
  `StreamArchived` event without any other append happening.
- `intial_fill_all/0` after an archive: `$archives` events aren't in `$all`,
  archived events aren't either, and an append afterwards succeeds (also listed
  in 0006).
- A stream whose pairing is broken (delete one of its `$all` rows, or add a
  second one, with raw SQL) can't be archived. `archive_stream` raises, and the
  stream, its `$all` rows and the archive tables are unchanged.
- The migration aborts with the documented error when a `$archives` stream
  already exists, and creates nothing.
- `append_to_stream("$archives", events)` returns `{:error, :system_stream}` and
  writes nothing.
- A subscriber of `ada` receives `{:stream_archived, "ada"}` and then nothing more,
  even after new `ada` events are appended. After resubscribing, it receives the
  new stream from version 0.
- A `$all` subscriber keeps working across the gap.
- The race: archive and immediately append to the new `ada` from another process.
  A new subscriber of `ada` receives every new event from version 0.
