defmodule EventstoreSqlite.Sync.Verify do
  @moduledoc false

  alias Ecto.Adapters.SQL
  alias EventstoreSqlite.RepoRead

  @doc """
  The history of every application stream name on this node, read in one
  transaction: its archived incarnations in archive order, then the live one.
  An incarnation is `%{first_id, count, archived, digest}`, where `first_id` is
  the id of its version-0 event and `digest` covers every event's id, type,
  data, metadata and timestamp in version order.
  """
  def histories do
    {:ok, histories} =
      RepoRead.transaction(fn ->
        archived = incarnations(archived_rows())
        live = incarnations(live_rows())

        Map.merge(archived, live, fn _stream, archived, live -> archived ++ live end)
      end)

    histories
  end

  @doc """
  The digest of the first `count` events of the incarnation of `stream_id`
  that starts with `first_id`, or `nil` when there is no such incarnation.
  """
  def prefix_digest(stream_id, first_id, count) do
    {:ok, digest} =
      RepoRead.transaction(fn ->
        (archived_rows(stream_id) ++ live_rows(stream_id))
        |> incarnations()
        |> Map.get(stream_id, [])
        |> Enum.find(&(&1.first_id == first_id))
        |> case do
          nil -> nil
          incarnation -> digest(Enum.take(incarnation.events, count))
        end
      end)

    digest
  end

  defp live_rows(stream_id \\ nil) do
    %{rows: rows} =
      SQL.query!(
        RepoRead,
        """
        SELECT s.stream_id, 0, s.stream_version, e.id, e.type, e.data, e.metadata, e.inserted_at
        FROM stream_events s JOIN events e ON e.id = s.event_id
        WHERE substr(s.stream_id, 1, 1) <> '$' AND (?1 IS NULL OR s.stream_id = ?1)
        ORDER BY s.stream_id, s.stream_version
        """,
        [stream_id]
      )

    Enum.map(rows, fn [stream, _archive, version | event] -> {stream, :live, version, event} end)
  end

  defp archived_rows(stream_id \\ nil) do
    %{rows: rows} =
      SQL.query!(
        RepoRead,
        """
        SELECT a.stream_id, a.id, ae.stream_version, e.id, e.type, e.data, e.metadata, e.inserted_at
        FROM archived_streams a
        JOIN archived_stream_events ae ON ae.archive_id = a.id
        JOIN events e ON e.id = ae.event_id
        WHERE substr(a.stream_id, 1, 1) <> '$' AND (?1 IS NULL OR a.stream_id = ?1)
        ORDER BY a.stream_id, a.id, ae.stream_version
        """,
        [stream_id]
      )

    Enum.map(rows, fn [stream, archive_id, version | event] -> {stream, {:archive, archive_id}, version, event} end)
  end

  defp incarnations(rows) do
    rows
    |> Enum.chunk_by(fn {stream, incarnation, _version, _event} -> {stream, incarnation} end)
    |> Enum.map(fn [{stream, incarnation, _, [first_id | _]} | _] = chunk ->
      events = Enum.map(chunk, fn {_, _, _, event} -> event_digest(event) end)

      {stream,
       %{
         first_id: first_id,
         count: length(events),
         archived: incarnation != :live,
         digest: digest(events),
         events: events
       }}
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp event_digest(event), do: :crypto.hash(:sha256, :erlang.term_to_binary(event))

  defp digest(event_digests) do
    event_digests
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
  end

  @doc """
  `histories/0` without the per-event digests, for sending to the peer.
  """
  def summaries, do: summarize(histories())

  @doc """
  Strips the per-event digests, which only the node that owns them needs.
  """
  def summarize(histories) do
    Map.new(histories, fn {stream, incarnations} ->
      {stream, Enum.map(incarnations, &Map.delete(&1, :events))}
    end)
  end

  @doc """
  Compares two summarized histories. `prefix_digest.(side, stream, first_id,
  count)` returns the digest of a prefix on `:local` or `:remote`.

  Returns `{:ok, lag}` where `lag` lists streams one side hasn't caught up on,
  or `{:error, forks}`. In `:strict` mode any difference is an error.
  """
  def compare(local, remote, mode, prefix_digest) do
    {forks, lag} =
      (Map.keys(local) ++ Map.keys(remote))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.reduce({[], []}, fn stream, {forks, lag} ->
        a = Map.get(local, stream, [])
        b = Map.get(remote, stream, [])

        cond do
          a == b -> {forks, lag}
          prefix?(a, b, &prefix_digest.(:remote, stream, &1, &2)) -> {forks, [{stream, :local_behind} | lag]}
          prefix?(b, a, &prefix_digest.(:local, stream, &1, &2)) -> {forks, [{stream, :remote_behind} | lag]}
          true -> {[{stream, %{local: a, remote: b}} | forks], lag}
        end
      end)

    cond do
      forks != [] -> {:error, Enum.reverse(forks)}
      mode == :strict and lag != [] -> {:error, Enum.reverse(lag)}
      true -> {:ok, Enum.reverse(lag)}
    end
  end

  defp prefix?([], _longer, _digest_of), do: true
  defp prefix?(shorter, longer, _digest_of) when length(shorter) > length(longer), do: false

  defp prefix?(shorter, longer, digest_of) do
    {init, [last]} = Enum.split(shorter, -1)
    {same, [counterpart | _]} = Enum.split(longer, length(init))

    init == same and last.first_id == counterpart.first_id and last.count <= counterpart.count and
      (not last.archived or (counterpart.archived and last.count == counterpart.count)) and
      ((last.count == counterpart.count and last.digest == counterpart.digest) or
         last.digest == digest_of.(last.first_id, last.count))
  end
end
