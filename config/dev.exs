import Config

database = Path.expand(System.get_env("DB", Path.expand("../dev.db", Path.dirname(__ENV__.file))))

config :eventstore_sqlite, EventstoreSqlite.RepoRead, database: database
config :eventstore_sqlite, EventstoreSqlite.RepoWrite, database: database

if node_id = System.get_env("NODE_ID") do
  config :eventstore_sqlite, :sync, node_id: node_id
end

config :tailwind,
  version: "4.3.0",
  live_eventstore: [
    args: ~w(--input=assets/css/live_eventstore.css --output=priv/static/live_eventstore.css),
    cd: Path.expand("..", __DIR__)
  ]
