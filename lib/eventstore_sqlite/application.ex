defmodule EventstoreSqlite.Application do
  @moduledoc false

  use Application

  def start(_type, _args) do
    children = [
      EventstoreSqlite.RepoWrite,
      EventstoreSqlite.RepoRead,
      EventstoreSqlite.Subscriptions,
      %{id: :pg, start: {:pg, :start_link, [EventstoreSqlite.Sync.Write.pg_scope()]}},
      {Registry, keys: :unique, name: EventstoreSqlite.Sync.Registry},
      {DynamicSupervisor, name: EventstoreSqlite.Sync.ReplicatorSupervisor, strategy: :one_for_one},
      EventstoreSqlite.Sync.Server
    ]

    opts = [strategy: :one_for_one, name: EventstoreSqlite.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
