# Issue — subscribers aren't told when their subscription ends

- **Status:** Version 1 done 2026-10-09: subscribers monitor
  `EventstoreSqlite.Subscriptions` themselves, following the pattern documented
  in `EventstoreSqlite.subscribe_to_stream/5` ("When the subscription process
  stops"). There is no API change. `test/eventstore_sqlite/subscription_restart_test.exs`
  kills the subscription process: a subscriber written that way misses nothing,
  and one that doesn't monitor misses everything after the restart. Version 2
  (below) stays open.
- **Found via:** 0008 (multi-node sync), whose first list of gaps said "remote
  subscriptions are dropped silently when the link breaks".

## Problem

`EventstoreSqlite.Subscriptions` keeps every registration in its process state.
Only an archive tells a subscriber that its subscription ended
(`{:stream_archived, stream}`). Two other ways it ends are silent.

### 1. The `Subscriptions` process crashes

The process reads events for its subscribers itself: `send_to_stream/3` calls
`EventstoreSqlite.read_stream_forward/2`. Anything that raises during that read
crashes it. The `Upcaster` moduledoc already says so: an exception "raised by an
upcaster fails the read, or crashes the subscription process". Other causes are
an event whose data can't be decoded and a database error.

`EventstoreSqlite.Application` restarts it (`:one_for_one`) with empty state.
Every registration is gone, and no subscriber is told. Every projection and
LiveView in the application stops receiving events, while the subscriber
processes keep running. Nothing is logged from the subscriber's side.

### 2. A subscriber on another node

`subscribe_to_stream/5` always calls the `Subscriptions` process on the caller's
own node (by registered name), but it accepts any pid. A pid from another node
gets registered. When the link drops, the `:DOWN` with `:noconnection` removes
the registration. The remote process isn't told, and after the link returns it
receives nothing. Messages in flight when the link dropped can also be lost.

Cross-node subscriptions aren't supported (decided in 0008: each node subscribes
to its own store), but nothing enforces that.

## Proposed fix

1. **Reject subscribers on other nodes.** `subscribe_to_stream/5` raises
   `ArgumentError` when `node(subscriber_pid) != node()`.
2. **Return a monitor ref.** `subscribe_to_stream/5` returns `{:ok, ref}`, where
   `ref` monitors `EventstoreSqlite.Subscriptions`. The monitor must belong to
   the subscriber process, so it is taken in the caller, which is normally the
   subscriber itself. (Open: what happens when `subscriber_pid` isn't the
   caller? Either require them to be the same, or document that the caller
   must pass the ref on.) On `{:DOWN, ref, ...}`, the subscriber subscribes
   again with its own checkpoint, the last processed version plus one. It may
   receive events it has already processed, but it never misses any. The store
   stays stateless about subscribers, and positions are the subscriber's
   responsibility (decided in 0008).
3. **Optional: isolate read failures.** Catch failures when reading for one
   stream, so they end only that stream's subscriptions (with a message such as
   `{:subscription_failed, stream, reason}`) instead of crashing the process for
   every stream.

The alternative to item 2 is no API change: document that subscribers must
monitor `EventstoreSqlite.Subscriptions` themselves. It's rejected as the
default because a forgotten monitor fails silently, which is the bug itself.

## Breaking changes

- The return value changes from `:ok` to `{:ok, ref}`. Callers matching `:ok`
  (for example `:ok = subscribe_to_stream(...)`) break. Each one needs a
  CHANGELOG entry and a `:DOWN` handler that resubscribes.
- Subscribing a pid on another node raises.

## Tests to write first

- Kill `EventstoreSqlite.Subscriptions` while a subscriber is registered. Today
  the subscriber receives nothing and later appends never arrive.
- An upcaster that raises on one event crashes `Subscriptions` and silently ends
  subscriptions to unrelated streams.
- Subscribing a pid on another `:peer` node is accepted today.

## Decision (2026-10-09)

Version 1 is documentation only: the subscriber is responsible for monitoring
`EventstoreSqlite.Subscriptions` and resubscribing from its own position. This
needs no breaking change, and it works when one process subscribes another,
as long as the subscriber itself monitors. The cost is that a subscriber that
doesn't follow the pattern still fails silently.

Still open, for a version 2 if that turns out to happen in practice:

- `subscribe_to_stream` returning `{:ok, ref}` (breaking). Callers that
  subscribe another process would have to pass the ref on; that is allowed,
  not refused.
- Rejecting subscriber pids on other nodes.
- Isolating read failures per stream, so one bad event doesn't restart the
  subscription process for everyone.

