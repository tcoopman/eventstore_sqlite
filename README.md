# EventstoreSqlite

**TODO: Add description**

## Sync between two nodes

Two instances of an application can each run their own store and hold every
event, with exactly one node allowed to write each stream. See
`EventstoreSqlite.Sync` and `EventstoreSqlite.Ownership`, the plan in
`docs/issues/0008-multi-node-sync-plan.md`, and the manual stress test in
`docs/sync-manual-stress-test.md`.

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

