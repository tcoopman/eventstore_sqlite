defmodule EventstoreSqlite.Sync.Export do
  @moduledoc false

  alias Ecto.Adapters.SQL
  alias EventstoreSqlite.RepoRead
  alias EventstoreSqlite.RepoWrite
  alias EventstoreSqlite.Sync.Failpoint
  alias EventstoreSqlite.Sync.Log
  alias EventstoreSqlite.Sync.State

  @protocol 1

  def protocol, do: @protocol

  @doc """
  Serves a peer's pull. The request also acknowledges everything up to
  `after_seq`, which lets this store prune its log.

  Returns `{:ok, %{entries, head, diverged, node_id}}`, or `{:error, reason}`
  when the peer must halt: `{:protocol, theirs, ours}`, `:sync_id_mismatch`,
  `{:wrong_node, node_id}`, `:unknown_peer`, `:ahead_of_origin`, `:pruned`,
  `:sync_disabled`.
  """
  def export(%{protocol: @protocol} = request) do
    {:ok, result} = RepoRead.transaction(fn -> read(RepoRead, request) end)

    with {:ok, response, previous_ack} <- result do
      if request.after_seq > previous_ack, do: record_ack(request.from, request.after_seq)
      {:ok, response}
    end
  end

  def export(%{protocol: protocol}), do: {:error, {:protocol, protocol, @protocol}}

  defp read(repo, request) do
    state = State.load(repo)

    with :ok <- validate(state, request) do
      head = Log.head(repo)

      entries =
        cond do
          request.after_seq > head -> {:error, :ahead_of_origin}
          request.after_seq == head -> {:ok, []}
          not Log.exists?(repo, request.after_seq + 1) -> {:error, :pruned}
          true -> {:ok, Log.entries_after(repo, request.after_seq, request.max_entries, request.max_bytes)}
        end

      with {:ok, entries} <- entries do
        response = %{entries: entries, head: head, diverged: state.diverged != nil, node_id: state.node_id}
        {:ok, response, ack(repo, request.from)}
      end
    end
  end

  defp validate(state, request) do
    cond do
      not state.enabled -> {:error, :sync_disabled}
      state.sync_id != request.sync_id -> {:error, :sync_id_mismatch}
      state.node_id != request.expect -> {:error, {:wrong_node, state.node_id}}
      not Map.has_key?(state.peers, request.from) -> {:error, :unknown_peer}
      true -> :ok
    end
  end

  defp ack(repo, peer) do
    case SQL.query!(repo, "SELECT seq FROM sync_acks WHERE peer = ?1", [peer]) do
      %{rows: [[seq]]} -> seq
      %{rows: []} -> -1
    end
  end

  defp record_ack(peer, seq) do
    RepoWrite.transact(
      fn repo ->
        state = State.load(repo)

        if Map.has_key?(state.peers, peer) do
          SQL.query!(
            repo,
            """
            INSERT INTO sync_acks (peer, seq) VALUES (?1, ?2)
            ON CONFLICT (peer) DO UPDATE SET seq = max(seq, excluded.seq)
            """,
            [peer, seq]
          )

          Failpoint.hit(:between_ack_and_prune)
          prune(repo, state)
        end

        {:ok, :done}
      end,
      mode: :immediate
    )
  end

  @doc """
  Deletes the log entries every current peer has acknowledged. A peer without
  an acknowledgement holds the log at the seq it was pinned at. With no peers,
  everything up to the head goes.
  """
  def prune(repo, %State{} = state) do
    %{rows: acks} = SQL.query!(repo, "SELECT peer, seq FROM sync_acks")
    acks = Map.new(acks, fn [peer, seq] -> {peer, seq} end)

    watermark =
      if map_size(state.peers) == 0 do
        Log.head(repo)
      else
        state.peers
        |> Enum.map(fn {peer, %{pinned_seq: pinned}} -> Map.get(acks, peer, pinned) end)
        |> Enum.min()
      end

    Log.prune_through(repo, watermark)
  end
end
