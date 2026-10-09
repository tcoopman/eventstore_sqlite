defmodule EventstoreSqlite.Sync.Supervisor do
  @moduledoc false
  use Supervisor

  def start_link(_), do: Supervisor.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_) do
    children = [
      {Registry, keys: :unique, name: EventstoreSqlite.Sync.Registry},
      EventstoreSqlite.Sync.Acks,
      {DynamicSupervisor, name: EventstoreSqlite.Sync.ReplicatorSupervisor, strategy: :one_for_one},
      EventstoreSqlite.Sync.Server
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
