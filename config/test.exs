import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :eventstore_sqlite, EventstoreSqlite.RepoWrite,
  database: Path.expand("../test.db", Path.dirname(__ENV__.file)),
  pool: Ecto.Adapters.SQL.Sandbox

config :eventstore_sqlite, EventstoreSqlite.RepoRead,
  database: Path.expand("../test.db", Path.dirname(__ENV__.file)),
  pool: Ecto.Adapters.SQL.Sandbox

# Print only warnings and errors during test
config :logger, level: :warning
