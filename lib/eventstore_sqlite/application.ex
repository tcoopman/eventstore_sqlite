defmodule EventstoreSqlite.Application do
  @moduledoc false

  use Application

  def start(_type, _args) do
    children = [
      EventstoreSqlite.Repo
    ]

    opts = [strategy: :one_for_one, name: EventstoreSqlite.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
