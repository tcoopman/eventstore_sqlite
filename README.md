# EventstoreSqlite

**TODO: Add description**

## Sync between two nodes

Two instances of an application can each run their own store and hold every
event, with exactly one node allowed to write each stream. See
`EventstoreSqlite.Sync` and `EventstoreSqlite.Ownership`, the plan in
`docs/issues/0008-multi-node-sync-plan.md`, and the manual stress test in
`docs/sync-manual-stress-test.md`.

## live_eventstore: a dashboard for your router

A read-only LiveView page of the store, mounted like Phoenix LiveDashboard. It
shows totals, the streams with their event counts and timestamps (searchable,
sortable, paged), and, with sync enabled, this node's role and the owner of
each stream. It needs `phoenix_live_view` in your application; this library
only depends on it optionally.

```elixir
# router.ex
import EventstoreSqlite.LiveEventstore.Router

scope "/" do
  pipe_through [:browser, :require_admin]
  live_eventstore "/eventstore"
end
```

Put it behind authentication: it shows stream names. See
`EventstoreSqlite.LiveEventstore.Router` for the options. To try it without an
app: `DB=demo.db mix ecto.create && DB=demo.db mix ecto.migrate && DB=demo.db
mix run dev/live_eventstore_demo.exs`, then open
<http://localhost:4000/eventstore>.

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `eventstore_sqlite` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:eventstore_sqlite, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/eventstore_sqlite>.

