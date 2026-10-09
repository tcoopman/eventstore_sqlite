# Manual stress test of multi-node sync

- **Status: TODO.** Not run yet. To be run together with the owner, on two
  machines.

A runbook for testing sync by hand with two running nodes: **main-node**, the
home node, and **secondary-node**, provisioned from a snapshot. It goes through
every situation the design has to survive: catch-up, writes from both sides, a
network cut, crashes, archives, live subscribers, a planned handover, and a
forced reclaim.

Use two machines on a LAN if possible. Two terminals on one machine work too;
step 6 explains how to cut the network without a second machine.

## Tools

The dev environment compiles `EventstoreSqlite.Sync.DevLoad`, a load
generator:

- `DevLoad.start(["orders:*"], 200)` appends 200 single events a second to
  `orders:1` … `orders:20`. Several loads can run at once.
- `DevLoad.stats()` shows `%{ok, not_owner, errors}` for this node.
- `DevLoad.stop()` stops every load on this node.

The dev config reads `DB` (the database file) and `NODE_ID` (the sync node
id) from the environment.

In every shell, run this first:

```elixir
alias EventstoreSqlite.{Sync, Ownership}
alias EventstoreSqlite.Sync.DevLoad
```

## Steps

1. **Start main-node.**

   ```sh
   DB=main-node.db mix ecto.create && DB=main-node.db mix ecto.migrate
   NODE_ID=main-node DB=main-node.db iex --name main_node@HOST1 --cookie sync -S mix
   ```

   ```elixir
   Sync.enable("main-node")                      # :ok
   ```

2. **Load on main-node**, running for the whole test:
   `DevLoad.start(["orders:*"], 200)`.

3. **Snapshot for secondary-node**, while the load runs:

   ```elixir
   Sync.snapshot("secondary-node.db", peer: "secondary-node-1")
   # {:ok, %{path: "secondary-node.db", snapshot_id: ..., head_seq: ...}}
   ```

   Copy `secondary-node.db` to the second machine and check that
   `sha256sum` matches on both sides.

4. **Start secondary-node** on the copy. It claims the copy at boot and logs
   `claimed the snapshot of main-node as secondary-node-1`.

   ```sh
   NODE_ID=secondary-node-1 DB=secondary-node.db iex --name secondary_node@HOST2 --cookie sync -S mix
   ```

   ```elixir
   Node.connect(:"main_node@HOST1")              # true
   Sync.status().peers["main-node"]              # state: :connected, lag reaches 0
   Sync.verify("main-node")                      # :ok, or {:lag, [...]} while main writes
   EventstoreSqlite.append_to_stream("orders:1", [%DevLoad.Event{text: "x"}])
   # {:error, :not_owner}: secondary-node owns nothing yet
   ```

5. **Assign streams to secondary-node.** On main-node:

   ```elixir
   {:ok, g} = Ownership.assign("venue:*", "secondary-node-1")
   Ownership.assign("venue:vip", "secondary-node-1")   # {:error, :overlap}
   EventstoreSqlite.append_to_stream("venue:1", [%DevLoad.Event{text: "x"}])
   # {:error, :not_owner}
   ```

   On secondary-node: `DevLoad.start(["venue:*"], 200)`. `DevLoad.stats()`
   shows `ok` climbing and no `not_owner`.

6. **Cut the network** for 2 minutes, and once for 15 minutes. Both nodes keep
   writing, and `Sync.status()` shows the peer as `:disconnected`.

   - Two machines: on secondary-node,
     `sudo iptables -A INPUT -s IP1 -j DROP; sudo iptables -A OUTPUT -d IP1 -j DROP`.
     Undo it with `-D` instead of `-A`.
   - One machine: on secondary-node, make the connection fail its
     authentication, so the replicator can't reconnect:

     ```elixir
     Node.set_cookie(:"main_node@HOST1", :wrong)
     Node.disconnect(:"main_node@HOST1")
     # later:
     Node.set_cookie(:"main_node@HOST1", :sync)
     Node.connect(:"main_node@HOST1")
     ```

   After restoring the network, time how long `lag` takes to reach 0 on both
   sides. Run `Sync.verify(peer)`. Then stop both loads briefly
   (`DevLoad.stop()`), wait for lag 0, and run `Sync.verify(peer, :strict)`,
   which must return `:ok`. Restart the loads.

7. **Crashes.** Find the OS pid with `System.pid()`, then `kill -9` it while
   the load runs. Restart with the same command and `Node.connect` again. Do
   this for secondary-node, then for main-node. Run `Sync.verify` after each.

8. **Disk-level check.** After step 7, run
   `sqlite3 FILE "PRAGMA integrity_check"` on both databases. It must print
   `ok`.

9. **Archive.** On secondary-node: `EventstoreSqlite.archive_stream("venue:1")`
   returns `:ok`. On main-node, the last event of `"$archives"` names
   `venue:1`
   (`EventstoreSqlite.read_stream_forward("$archives") |> List.last()`). The
   load writes `venue:1` again on secondary-node, and the new stream shows up on
   main-node starting at version 0. `Sync.verify` compares both incarnations.

10. **Live subscribers.** In the app (for example tickets-admin), open a
    LiveView on secondary-node for a stream main-node writes and one for a
    stream secondary-node writes. Both update live, also after steps 6 and 7.

11. **Planned handover.** On main-node, `Ownership.reclaim(g)` returns `:ok`
    while the load on secondary-node runs. Note how long it takes. Afterwards
    `DevLoad.stats()` on secondary-node shows `not_owner` climbing. On
    main-node, `DevLoad.start(["venue:*"], 200)`. Stop the loads, wait for lag
    0, and run `Sync.verify(peer, :strict)`, which must return `:ok`.

12. **Forced reclaim.**
    - Retire the first secondary-node: stop its loads, wait for lag 0, run
      `Sync.remove_peer("secondary-node-1")` on main-node (`:ok`), and stop
      that BEAM.
    - Provision a new one: `Sync.snapshot("secondary-node-2.db", peer:
      "secondary-node-2")`, start it with `NODE_ID=secondary-node-2`, connect,
      `{:ok, g2} = Ownership.assign("venue:*", "secondary-node-2")`, and
      `DevLoad.start(["venue:*"], 200)` on it.
    - Cut the network (step 6). On main-node:
      `Ownership.revoke_node("secondary-node-2")` returns `{:ok, [g2]}`, and
      `Sync.status().peers["secondary-node-2"].state` is `:retired`. Then
      `DevLoad.start(["venue:*"], 200)` on main-node.
    - Restore the network. On main-node, `Sync.status()` shows the peer as
      `:diverged`, then `:drained`. `Sync.quarantine()` lists the entries
      secondary-node-2 wrote after the last pull before the revoke. On
      secondary-node-2, `Sync.status().diverged` names main-node, and every
      append returns `{:error, :diverged}`, also after a restart.

13. **Teardown.** On main-node: `DevLoad.stop()`, then
    `Sync.remove_peer("secondary-node-2")` (`:ok` once drained), then
    `Sync.disable()` (`:ok`).
    `Ecto.Adapters.SQL.query!(EventstoreSqlite.RepoRead, "SELECT count(*) FROM sync_log").rows`
    must be `[[0]]`.

14. **Throughout**, watch `:observer.start()`: the memory and message queue
    of `EventstoreSqlite.Subscriptions` and of the replicators under
    `EventstoreSqlite.Sync.ReplicatorSupervisor`. Also watch the size of the
    database and `-wal` files.

## Pass criteria

- `Sync.verify` is `:ok` (or `{:lag, _}` while writing) after every step from 4
  to 11. It never returns `{:error, _}`.
- No halts outside step 12: `Sync.status().peers[peer].halted` stays `nil`.
- Catch-up after a 2-minute outage at 200 events/s per node takes under 10 s.
- `PRAGMA integrity_check` is `ok` on both files.

## Automated counterpart

`mix eventstore.sync_stress` runs a randomized version of all of this against
two BEAMs on one machine, with partitions, replicator kills, `kill -9`-style
node kills, handovers and archives. At the end it checks that no acknowledged
write is lost, both nodes are identical, and a forced reclaim quarantines
exactly the unpulled writes.

- `SYNC_STRESS_SECONDS` sets the duration (default 300).
- `SYNC_STRESS_SEED` replays a run.
- `SYNC_STRESS_MAX_PARTITION_MS` sets the longest partition (default 30 000).
