import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :eventstore_sqlite, EventstoreSqlite.Repo,
  database: Path.expand("../bench.db", Path.dirname(__ENV__.file)),
  pool_size: 5,
  journal_mode: :wal,
  synchronous: :normal,
  cache_size:  1_000_000_000,
  busy_timeout: 5_000

# Print only warnings and errors during test
config :logger, level: :warning
