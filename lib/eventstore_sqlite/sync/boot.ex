defmodule EventstoreSqlite.Sync.Boot do
  @moduledoc false

  alias Ecto.Adapters.SQL
  alias EventstoreSqlite.Sync.State

  @doc """
  Decides what a store needs at boot, given the configured node id:

    * `:ok` — nothing to do;
    * `{:claim, snapshot}` — the store is a snapshot made for this node;
    * `{:error, message}` — the store must not start under this configuration.

  A store whose sync tables don't exist yet (migrations not run) is treated as
  having sync disabled.
  """
  def check(repo, configured_node_id) do
    if tables_exist?(repo) do
      repo |> State.load() |> decide(configured_node_id)
    else
      :ok
    end
  end

  defp decide(%State{snapshot: %{for_node: node_id} = snapshot}, node_id) when is_binary(node_id), do: {:claim, snapshot}

  defp decide(%State{snapshot: %{} = snapshot}, configured) do
    {:error,
     "this database is a sync snapshot made for node #{inspect(snapshot.for_node)}, " <>
       "but the configured node id is #{inspect(configured)}. Configure " <>
       "`config :eventstore_sqlite, :sync, node_id: #{inspect(snapshot.for_node)}` to claim it."}
  end

  defp decide(%State{enabled: false}, _configured), do: :ok

  defp decide(%State{node_id: node_id}, node_id), do: :ok

  defp decide(%State{node_id: node_id}, nil) do
    {:error,
     "sync is enabled in this database for node #{inspect(node_id)}, but no node id is " <>
       "configured. Configure `config :eventstore_sqlite, :sync, node_id: #{inspect(node_id)}`."}
  end

  defp decide(%State{node_id: node_id}, configured) do
    {:error,
     "this database belongs to sync node #{inspect(node_id)}, but the configured node id is " <>
       "#{inspect(configured)}. A copy of another node's database can only be used through " <>
       "EventstoreSqlite.Sync.snapshot/2."}
  end

  defp tables_exist?(repo) do
    %{rows: rows} = SQL.query!(repo, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'sync_state'")
    rows != []
  end
end
