defmodule EventstoreSqlite.Sync.Server do
  @moduledoc false
  use GenServer

  alias EventstoreSqlite.RepoWrite
  alias EventstoreSqlite.Sync
  alias EventstoreSqlite.Sync.Boot

  require Logger

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def refresh do
    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, :refresh)
    :ok
  end

  @impl true
  def init(_) do
    case Boot.check(RepoWrite, Sync.configured_node_id()) do
      :ok ->
        {:ok, %{}}

      {:error, message} ->
        Logger.error("eventstore_sqlite sync: " <> message)
        {:stop, {:sync_identity, message}}
    end
  end

  @impl true
  def handle_cast(:refresh, state), do: {:noreply, state}
end
