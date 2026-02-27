# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :eventstore_sqlite, EventstoreSqlite.RepoRead,
  pool_size: 5,
  journal_mode: :wal,
  synchronous: :normal,
  cache_size: -2_000,
  busy_timeout: 5_000

config :eventstore_sqlite, EventstoreSqlite.RepoWrite,
  pool_size: 1,
  journal_mode: :wal,
  synchronous: :normal,
  cache_size: -2_000,
  busy_timeout: 5_000

config :eventstore_sqlite,
  ecto_repos: [EventstoreSqlite.RepoRead, EventstoreSqlite.RepoWrite]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  # Import environment specific config. This must remain at the bottom
  # of this file so it overrides the configuration defined above.
  metadata: [:request_id]

import_config "#{config_env()}.exs"
