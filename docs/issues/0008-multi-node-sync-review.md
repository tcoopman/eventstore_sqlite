# Review log — 0008 multi-node sync plan

Two outside models reviewed [the plan](0008-multi-node-sync-plan.md) through
OpenRouter, each in its own ongoing conversation: `openai/gpt-6.1-sol-pro`
("GPT") and `google/gemini-pro-latest` ("Gemini"). Each received the plan and
the current source of `eventstore_sqlite.ex`, `subscriptions.ex`, `event.ex`
and `reader.ex`. They were told the "Decisions" section was settled.

| Round | Plan rev | GPT | Gemini |
| --- | --- | --- | --- |
| 1 | 1 | changes requested (5 blockers, 10 majors) | changes requested (3 majors, 4 minors) |
| 2 | 2 | changes requested (2 blockers, 7 majors, 1 minor) | changes requested (1 major, 2 minors) |
| 3 | 3 | changes requested (1 blocker, 4 majors, 1 minor) | **approved** |
| 4 | 4 | changes requested (3 majors, 1 minor) | — |
| 5 | 5 | changes requested (1 major, 2 minors) | — |
| 6 | 6 | **approved** (3 minors, applied in rev 7) | — |
| 7 | 7 | — | **approved** (re-confirmed the final version) |

Every point was accepted. None was rejected. Where a point pushed toward more
complexity, the plan was simplified instead (disjoint assignments,
node-level forced reclaim, no in-memory cache).

## Round 1

| Raised by | Point | Outcome |
| --- | --- | --- |
| GPT | A forced reclaim contradicts "one writer". Also, "after the reclaim" is wrong: writes acked *before* the reclaim but not yet imported are also lost. | I1 and I3 now state the exception. Everything carrying the revoked generation that home hadn't imported is quarantined. |
| GPT | Overlapping selectors (`venue:*` against `venue:vip`) break handover safety. | **Simplified:** assignments must be disjoint, and `assign` returns `{:error, :overlap}` (assumption A10). |
| GPT | Ownership changes from different nodes aren't ordered against each other. A late release can undo a newer assignment. | **Ownership generations:** every assignment has a generation, which is home's log seq. Releases and reclaims name it, and a stale one is ignored. |
| GPT | Quarantine checked by "who owns it now" lets old entries through after a reassignment. | Every append or archive entry records its authorizing generation, and import authorizes by generation. |
| GPT, Gemini | Archive import isn't atomic with the cursor, would log the entry again, and would run the ownership check. | New `Subscriptions.apply_archive/2`: one transaction inside the GenServer does the cursor check, the archive and the cursor update. It doesn't log or check ownership. |
| GPT | The `:persistent_term` cache of "sync enabled" can race with writes. | **Cache dropped.** State is read inside the write transaction on the single write connection. |
| GPT | "Halted" was contradictory: A7 refused writes, while import continued them. | New section, "Halted versus diverged", with the safety argument. Halted nodes keep writing their own streams. |
| GPT | A snapshot claim could be repeated or claimed by the wrong node. | A `SnapshotCreated` marker written only into the copy, naming the intended node. Each copy can be claimed once. |
| GPT | `VACUUM INTO` doesn't fsync, and a failed snapshot leaves pruning pinned. | Temp file, check, fsync, then rename. Cleanup on failure. |
| GPT | Export, ack and prune have no transaction boundaries, and identity isn't checked. | One read transaction per export. The request carries protocol, `sync_id`, sender and expected receiver. "Ahead of origin" is rejected, and an idle log is told apart from a pruned one. |
| GPT, Gemini | The 1000-event transaction bound would split a large batch. | The bound only falls between entries. A large entry gets its own transaction. |
| GPT | `verify` could report success falsely: it left out `type`, ignored archives, and skipped streams. | Rewritten (finalized in round 2). |
| GPT | The stress test ignored archives and stream reuse. | The harness models stream incarnations. |
| GPT | Chaos via `disconnect_node` heals itself through auto-connect. | `:peer` over stdio with `dist_auto_connect never`, plus failpoints at every commit boundary. |
| GPT | Phase 3 enabled replication before ownership checks existed. | The owner check with home as the default moved to phase 1, so a replica can never write. |
| Gemini | Imported ownership entries must not be logged. Version 0 means "no stream". Archive errors must halt. Foreign keys. | All accepted. Foreign keys are on by default in `ecto_sqlite3`; pruning deletes explicitly anyway. |

## Round 2

| Raised by | Point | Outcome |
| --- | --- | --- |
| GPT | A `reclaim(selector)` retry could release a *later* assignment. | `reclaim/2` takes a **generation**. `assign` returns `{:ok, G}`. |
| GPT | Authorization didn't check the stream is inside the generation's selector, nor who may send ownership entries. | Full authorization rules: selector match, assign/revoke only from home, release only from the owner. |
| GPT | The snapshot marker could end up in a `-wal` sidecar file. | A raw connection with `journal_mode=DELETE`, then an explicit `:file.sync`. |
| GPT | Snapshot cleanup could remove a valid peer. | Snapshots are serialized. A peer is removed only if this call created it. |
| GPT | Archive outcomes (duplicate or quarantined) must not end subscriptions. | `:applied | :duplicate | :quarantined`. Only `:applied` cleans up. |
| GPT | **A process dying between commit and ping leaves idle subscribers stuck forever. The same bug exists today for local appends.** | A `Subscriptions` reconciliation tick (1 s, one query), plus `ping_all` when the replicator starts. |
| GPT | `verify(:prefix)` is wrong across archive, reuse and handover. | **Redesigned:** per stream name, a history of incarnations identified by their version-0 event id. One side must be a prefix of the other, which needs no ownership or timing knowledge. |
| GPT | Forcing one generation diverges the whole secondary-node, but its other generations stay assigned. | **Simplified:** the forced reclaim is node-level, `revoke_node/1`. It revokes everything and retires the id. |
| GPT | An export of a pruned-empty log was unspecified, and peer removal could race the ack. | `:pruned` is explicit. Membership is checked again in the ack transaction. |
| GPT | The tests implied more than one secondary-node at a time. | One secondary-node at a time. The stale-release variant moved to hand-built import fixtures. |
| Gemini | The snapshot marker can't go through the store API, which would deadlock or touch main-node. | Raw Exqlite connection. |
| Gemini | A diverged secondary-node must keep exporting, so home can quarantine its late entries. | Accepted. |
| Gemini | `sqlite_sequence` reset. | `DELETE FROM sqlite_sequence WHERE name = 'sync_log'`. |

## Round 3 (Gemini approved here)

| Raised by | Point | Outcome |
| --- | --- | --- |
| GPT | **A secondary-node that released locally, then got revoked, wouldn't diverge**, because it "holds no generation". | A `NodeRevoked` naming the node diverges it unconditionally. |
| GPT | The node-level revoke had no atomic wire format. | One compound `NodeRevoked` entry, imported in one transaction. |
| GPT | The `release` retry answer wasn't durable across pruning. | `sync_released(generation, owner, release_seq)` table, replayed from events. |
| GPT | The existing `run_archive` catches exceptions, so cleanup after commit could be skipped silently. | The `catch` only wraps the transaction. A failure after commit crashes `Subscriptions` on purpose. |
| GPT | A forced `remove_peer` could destroy quarantine-bound writes. | A **drain** barrier is required. `discard_unpulled: true` is a documented exception. |
| GPT | I1 and I5 wording. | Qualified. |

## Round 4

| Raised by | Point | Outcome |
| --- | --- | --- |
| GPT | Removing a retired peer would deadlock waiting for an ack it can never send. | Retired peers need the drain only, not an ack. |
| GPT | Entries after the revoke in the same batch could still be applied. | `NodeRevoked` is always the last entry in its transaction. Export reads head and diverged flag in one snapshot. |
| GPT | **A diverged secondary-node could call `disable()` and start writing again.** | Administration guards: lifecycle operations are home-only and refused when diverged. The write path checks diverged first. |
| GPT | Leftover contradictions. | Fixed. |

## Round 5

| Raised by | Point | Outcome |
| --- | --- | --- |
| GPT | A diverged node could resume importing after a restart. | Halt and divergence are durable fences, checked at replicator start and in every import transaction. `resume` never clears divergence. |
| GPT | The "log empty" check in the stress test was impossible before removing the secondary-node. | The harness drains and removes the secondary-node first. |
| GPT | `enable` after `disable`; the `NodeDiverged` fields. | Re-enable starts a new group. `NodeDiverged{node_id, revoked_by, revoke_seq}`. |

## Round 6 (GPT approved), then round 7 (Gemini re-approved)

GPT's last minor points, applied in revision 7: prune when a peer is removed,
what a re-enable resets versus keeps, and I3 scoped to active, non-retired
peers.
