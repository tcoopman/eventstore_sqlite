import Config

config :eventstore_sqlite, EventstoreSqlite.RepoRead, database: Path.expand("../dev.db", Path.dirname(__ENV__.file))

# Configure your database
#
config :eventstore_sqlite, EventstoreSqlite.RepoWrite, database: Path.expand("../dev.db", Path.dirname(__ENV__.file))
