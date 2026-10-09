defmodule EventstoreSqlite.Sync.Acks do
  @moduledoc false
  use GenServer

  alias Ecto.Adapters.SQL
  alias EventstoreSqlite.Changes
  alias EventstoreSqlite.RepoWrite
  alias EventstoreSqlite.Sync.Export
  alias EventstoreSqlite.Sync.Failpoint
  alias EventstoreSqlite.Sync.State

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  Records that `peer` has everything up to `seq`, after the export that carries
  it has replied: an export never waits for the write lock. Acknowledgements
  only allow pruning, so recording one late is harmless; only the newest per
  peer is written.
  """
  def record(peer, seq), do: GenServer.cast(__MODULE__, {:ack, peer, seq})

  @doc false
  def flush, do: GenServer.call(__MODULE__, :flush, 30_000)

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_cast({:ack, peer, seq}, pending) do
    {:noreply, Map.update(pending, peer, seq, &max(&1, seq)), {:continue, :write}}
  end

  @impl true
  def handle_call(:flush, _from, pending), do: {:reply, :ok, write(pending)}

  @impl true
  def handle_continue(:write, pending), do: {:noreply, write(pending)}

  defp write(pending) when map_size(pending) == 0, do: pending

  defp write(pending) do
    {:ok, advanced?} = RepoWrite.transact(&record_acks(&1, pending), mode: :immediate)
    if advanced?, do: Changes.notify(:sync)
    %{}
  end

  defp record_acks(repo, pending) do
    state = State.load(repo)

    advanced =
      for {peer, seq} <- pending, Map.has_key?(state.peers, peer) do
        %{num_rows: rows} =
          SQL.query!(
            repo,
            """
            INSERT INTO sync_acks (peer, seq) VALUES (?1, ?2)
            ON CONFLICT (peer) DO UPDATE SET seq = excluded.seq WHERE excluded.seq > sync_acks.seq
            """,
            [peer, seq]
          )

        rows
      end

    Failpoint.hit(:between_ack_and_prune)
    Export.prune(repo, state)
    {:ok, Enum.sum(advanced) > 0}
  end
end
