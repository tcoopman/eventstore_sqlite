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
shows the streams with their versions and timestamps (newest first or by name,
searchable and paged) and, with sync enabled, this node's role, its peers (state, lag, last
applied entry, errors), the change log, ownership assignments with each
stream's owner, and recent sync history. Click a stream to page through its
events, newest first, and open one to see its envelope, metadata and data as
JSON; large payloads aren't rendered, but every event can be downloaded as
JSON. It updates when the store changes, through
`EventstoreSqlite.subscribe_to_changes/1`, and only uses the public API.

It is built with [Fluxon UI](https://fluxonui.com), so it needs both
`phoenix_live_view` and `fluxon` in your application; this library depends on
both optionally, and compiles the dashboard only when both are present. It
serves its own compiled CSS and JavaScript, so your asset build needs no
changes.

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

After changing the dashboard's markup, rebuild its stylesheet with
`mix assets.build` and commit `priv/static/live_eventstore.css`: Tailwind only
generates the classes it finds in the source.

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

