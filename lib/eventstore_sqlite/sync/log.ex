defmodule EventstoreSqlite.Sync.Log do
  @moduledoc false

  alias Ecto.Adapters.SQL

  def append(repo, kind, attrs) when kind in [:append, :archive, :ownership] do
    payload = if Map.has_key?(attrs, :payload), do: {:blob, :erlang.term_to_binary(attrs.payload)}

    %{rows: [[seq]]} =
      SQL.query!(
        repo,
        """
        INSERT INTO sync_log (kind, stream_id, stream_version, generation, payload, inserted_at)
        VALUES (?1, ?2, ?3, ?4, ?5, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
        RETURNING seq
        """,
        [Atom.to_string(kind), attrs[:stream_id], attrs[:stream_version], attrs[:generation], payload]
      )

    attrs
    |> Map.get(:event_ids, [])
    |> Enum.with_index()
    |> Enum.chunk_every(300)
    |> Enum.each(fn chunk ->
      placeholders = Enum.map_join(chunk, ",", fn _ -> "(?, ?, ?)" end)
      params = Enum.flat_map(chunk, fn {event_id, position} -> [seq, position, event_id] end)
      SQL.query!(repo, "INSERT INTO sync_log_events (seq, position, event_id) VALUES #{placeholders}", params)
    end)

    seq
  end

  @doc """
  The last seq this store has handed out. It comes from `sqlite_sequence`, so it
  stays correct after the log has been pruned empty.
  """
  def head(repo) do
    case SQL.query!(repo, "SELECT seq FROM sqlite_sequence WHERE name = 'sync_log'") do
      %{rows: [[seq]]} -> seq
      %{rows: []} -> 0
    end
  end

  @doc """
  The oldest entry still in the log, and how many are retained. Entries are
  only ever pruned from the start, and a rolled-back append hands out no seq,
  so the log holds every seq from `oldest` to the head.
  """
  def retained(repo) do
    case SQL.query!(repo, "SELECT min(seq) FROM sync_log") do
      %{rows: [[nil]]} -> %{oldest: nil, entries: 0}
      %{rows: [[oldest]]} -> %{oldest: oldest, entries: head(repo) - oldest + 1}
    end
  end

  def exists?(repo, seq) do
    %{rows: rows} = SQL.query!(repo, "SELECT 1 FROM sync_log WHERE seq = ?1", [seq])
    rows != []
  end

  @doc """
  Entries after `after_seq`, oldest first: at least one when there is any, and
  otherwise at most `max_entries` and about `max_bytes` of event data. An entry
  is never split.
  """
  def entries_after(repo, after_seq, max_entries, max_bytes) do
    %{rows: rows} =
      SQL.query!(
        repo,
        """
        SELECT seq, kind, stream_id, stream_version, generation, payload
        FROM sync_log WHERE seq > ?1 ORDER BY seq LIMIT ?2
        """,
        [after_seq, max_entries]
      )

    take_within(rows, repo, max_bytes, 0, [])
  end

  defp take_within([], _repo, _max_bytes, _bytes, acc), do: Enum.reverse(acc)

  defp take_within([row | rows], repo, max_bytes, bytes, acc) do
    entry = load_entry(repo, row)
    bytes = bytes + entry_bytes(entry)

    cond do
      acc == [] -> take_within(rows, repo, max_bytes, bytes, [entry])
      bytes > max_bytes -> Enum.reverse(acc)
      true -> take_within(rows, repo, max_bytes, bytes, [entry | acc])
    end
  end

  defp entry_bytes(entry) do
    Enum.reduce(entry.events, 0, fn event, sum ->
      sum + byte_size(event.data) + byte_size(event.metadata || "")
    end)
  end

  defp load_entry(repo, [seq, kind, stream_id, stream_version, generation, payload]) do
    %{
      seq: seq,
      kind: String.to_existing_atom(kind),
      stream_id: stream_id,
      stream_version: stream_version,
      generation: generation,
      payload: payload && :erlang.binary_to_term(payload),
      events: load_events(repo, seq)
    }
  end

  defp load_events(repo, seq) do
    %{rows: rows} =
      SQL.query!(
        repo,
        """
        SELECT e.id, e.type, e.data, e.metadata, e.inserted_at
        FROM sync_log_events l JOIN events e ON e.id = l.event_id
        WHERE l.seq = ?1 ORDER BY l.position
        """,
        [seq]
      )

    Enum.map(rows, fn [id, type, data, metadata, inserted_at] ->
      %{id: id, type: type, data: data, metadata: metadata, inserted_at: inserted_at}
    end)
  end

  def prune_through(repo, seq) do
    SQL.query!(repo, "DELETE FROM sync_log_events WHERE seq <= ?1", [seq])
    SQL.query!(repo, "DELETE FROM sync_log WHERE seq <= ?1", [seq])
    :ok
  end

  def delete_all(repo) do
    SQL.query!(repo, "DELETE FROM sync_log_events")
    SQL.query!(repo, "DELETE FROM sync_log")
    :ok
  end
end
