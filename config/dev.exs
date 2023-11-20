import Config

# Configure your database
#
config :eventstore_sqlite, EventstoreSqlite.Repo,
  database: Path.expand("../dev.db", Path.dirname(__ENV__.file)),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox
