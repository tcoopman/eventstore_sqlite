defmodule EventstoreSqlite.Sync.Snapshot do
  @moduledoc false

  alias Ecto.Adapters.SQL
  alias EventstoreSqlite.Event
  alias EventstoreSqlite.RepoRead
  alias EventstoreSqlite.RepoWrite
  alias EventstoreSqlite.Sync
  alias EventstoreSqlite.Sync.Failpoint
  alias EventstoreSqlite.Sync.Log
  alias EventstoreSqlite.Sync.State
  alias EventstoreSqlite.SystemEvents.PeerAdded
  alias EventstoreSqlite.SystemEvents.PeerRemoved
  alias EventstoreSqlite.SystemEvents.SnapshotClaimed
  alias EventstoreSqlite.SystemEvents.SnapshotCreated

  require Logger

  @doc """
  Writes a consistent copy of this store to `path` for the new peer `peer`.
  Runs in `EventstoreSqlite.Sync.Server`, so snapshots never overlap.
  """
  def create(path, peer) do
    tmp = path <> ".tmp"

    cond do
      File.exists?(path) -> {:error, {:exists, path}}
      File.exists?(tmp) -> {:error, {:exists, tmp}}
      true -> create(path, tmp, peer)
    end
  end

  defp create(path, tmp, peer) do
    with {:ok, created?} <- pin_peer(peer) do
      try do
        SQL.query!(RepoRead, "VACUUM INTO ?1", [tmp])
        Failpoint.hit(:snapshot_after_vacuum)
        snapshot = mark(tmp, peer)
        fsync(tmp)
        Failpoint.hit(:snapshot_before_rename)
        File.rename!(tmp, path)
        fsync_directory(Path.dirname(path))
        {:ok, %{path: path, snapshot_id: snapshot.snapshot_id, head_seq: snapshot.head_seq}}
      rescue
        error ->
          File.rm(tmp)
          if created?, do: unpin_peer(peer)
          {:error, {:snapshot_failed, Exception.message(error)}}
      end
    end
  end

  defp pin_peer(peer) do
    Sync.transact_state(fn repo, state ->
      with :ok <- Sync.guard_home(state) do
        others = state.peers |> Map.keys() |> List.delete(peer)

        cond do
          peer == state.node_id -> {:error, :self}
          Map.has_key?(state.retired, peer) -> {:error, :retired}
          others != [] -> {:error, {:peer_exists, hd(others)}}
          Map.has_key?(state.peers, peer) and acked?(repo, peer) -> {:error, :peer_already_active}
          Map.has_key?(state.peers, peer) -> {:ok, state, {:ok, false}}
          true -> {:ok, State.record(repo, state, %PeerAdded{node_id: peer, pinned_seq: Log.head(repo)}), {:ok, true}}
        end
      end
    end)
  end

  defp acked?(repo, peer) do
    %{rows: rows} = SQL.query!(repo, "SELECT 1 FROM sync_acks WHERE peer = ?1", [peer])
    rows != []
  end

  defp unpin_peer(peer) do
    Sync.transact_state(fn repo, state ->
      if Map.has_key?(state.peers, peer) and not acked?(repo, peer) and State.generations_of(state, peer) == [] do
        {:ok, State.record(repo, state, %PeerRemoved{node_id: peer})}
      else
        {:ok, state}
      end
    end)
  end

  defp mark(tmp, peer) do
    {:ok, conn} = Exqlite.Sqlite3.open(tmp)

    try do
      exec!(conn, "PRAGMA journal_mode = DELETE")
      exec!(conn, "PRAGMA synchronous = FULL")
      [["ok"]] = rows!(conn, "PRAGMA quick_check", [])
      exec!(conn, "BEGIN IMMEDIATE")

      head_seq =
        case rows!(conn, "SELECT seq FROM sqlite_sequence WHERE name = 'sync_log'", []) do
          [[seq]] -> seq
          [] -> 0
        end

      [[state_blob]] = rows!(conn, "SELECT value FROM sync_state WHERE key = 'state'", [])
      state = :erlang.binary_to_term(state_blob)

      snapshot = %SnapshotCreated{
        snapshot_id: Ecto.UUID.generate(),
        for_node: peer,
        snapshot_of: state.node_id,
        head_seq: head_seq
      }

      insert_sync_event(conn, snapshot)
      state = State.apply(state, snapshot)

      rows!(conn, "UPDATE sync_state SET value = ?1 WHERE key = 'state'", [{:blob, :erlang.term_to_binary(state)}])
      exec!(conn, "COMMIT")
      snapshot
    after
      Exqlite.Sqlite3.close(conn)
    end
  end

  defp insert_sync_event(conn, data) do
    event = Event.new(data)
    stream = State.sync_stream()
    [[version]] = rows!(conn, "SELECT stream_version FROM streams WHERE stream_id = ?1", [stream])

    rows!(conn, "INSERT INTO events (id, type, data, metadata, inserted_at) VALUES (?1, ?2, ?3, NULL, ?4)", [
      event.id,
      event.type,
      {:blob, event.data},
      DateTime.to_iso8601(event.inserted_at)
    ])

    rows!(
      conn,
      """
      INSERT INTO stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version)
      VALUES (?1, ?2, ?3, ?2, ?3)
      """,
      [event.id, stream, version]
    )

    rows!(conn, "UPDATE streams SET stream_version = ?1 WHERE stream_id = ?2", [version + 1, stream])
  end

  defp exec!(conn, sql), do: :ok = Exqlite.Sqlite3.execute(conn, sql)

  defp rows!(conn, sql, params) do
    {:ok, statement} = Exqlite.Sqlite3.prepare(conn, sql)

    try do
      :ok = Exqlite.Sqlite3.bind(statement, params)
      {:ok, rows} = Exqlite.Sqlite3.fetch_all(conn, statement)
      rows
    after
      Exqlite.Sqlite3.release(conn, statement)
    end
  end

  defp fsync(path) do
    {:ok, fd} = :file.open(String.to_charlist(path), [:read, :write, :raw, :binary])
    :ok = :file.sync(fd)
    :ok = :file.close(fd)
  end

  defp fsync_directory(dir) do
    case :file.open(String.to_charlist(dir), [:read, :raw]) do
      {:ok, fd} ->
        :file.sync(fd)
        :file.close(fd)

      {:error, _} ->
        :ok
    end
  end

  @doc """
  Makes this store, a snapshot made for `node_id`, the store of that node. Runs
  at boot, before anything else uses the store.
  """
  def claim(%SnapshotCreated{} = snapshot, node_id) do
    result =
      RepoWrite.transact(
        fn repo ->
          case SQL.query!(repo, "PRAGMA quick_check").rows do
            [["ok"]] -> claim_in_transaction(repo, snapshot, node_id)
            rows -> {:error, "the snapshot failed its integrity check: #{inspect(rows)}"}
          end
        end,
        mode: :immediate
      )

    case result do
      {:ok, _} ->
        Logger.info("eventstore_sqlite sync: claimed the snapshot of #{snapshot.snapshot_of} as #{node_id}")
        :ok

      error ->
        error
    end
  end

  defp claim_in_transaction(repo, snapshot, node_id) do
    for table <- ~w(sync_log_events sync_log sync_acks sync_quarantine sync_cursors) do
      SQL.query!(repo, "DELETE FROM #{table}")
    end

    SQL.query!(repo, "DELETE FROM sqlite_sequence WHERE name = 'sync_log'")

    SQL.query!(
      repo,
      "INSERT INTO sync_cursors (origin, seq, origin_head, origin_diverged) VALUES (?1, ?2, ?2, 0)",
      [snapshot.snapshot_of, snapshot.head_seq]
    )

    claimed = %SnapshotClaimed{
      snapshot_id: snapshot.snapshot_id,
      node_id: node_id,
      snapshot_of: snapshot.snapshot_of,
      cursor: snapshot.head_seq
    }

    state = State.record(repo, State.load(repo), claimed)
    Failpoint.hit(:claim_before_commit)
    {:ok, State.save(repo, state)}
  end
end
