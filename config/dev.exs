import Config

# Configure your database
#
config :eventstore_sqlite, EventstoreSqlite.RepoWrite,
  database: Path.expand("../dev.db", Path.dirname(__ENV__.file)),
  pool: Ecto.Adapters.SQL.Sandbox

config :eventstore_sqlite, EventstoreSqlite.RepoRead,
  database: Path.expand("../dev.db", Path.dirname(__ENV__.file)),
  pool: Ecto.Adapters.SQL.Sandbox
