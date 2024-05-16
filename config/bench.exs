import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :eventstore_sqlite, EventstoreSqlite.RepoWrite,
  database: Path.expand("../bench.db", Path.dirname(__ENV__.file))

config :eventstore_sqlite, EventstoreSqlite.RepoRead,
  database: Path.expand("../bench.db", Path.dirname(__ENV__.file))

# Print only warnings and errors during test
config :logger, level: :warning
