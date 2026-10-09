defmodule EventstoreSqlite.LiveEventstore.Overview do
  @moduledoc """
  Read-only queries behind the live_eventstore pages. Doesn't depend on
  Phoenix.
  """

  alias Ecto.Adapters.SQL
  alias EventstoreSqlite.RepoRead
  alias EventstoreSqlite.Sync.State

  @sorts %{name: "s.stream_id", events: "s.stream_version", created: "s.inserted_at"}
  @default_per_page 50

  def sorts, do: Map.keys(@sorts)

  @doc """
  Totals for the whole store, and this node's sync state.
  """
  def summary do
    [[streams, events, archived, system]] =
      query("""
      SELECT (SELECT count(*) FROM streams WHERE substr(stream_id, 1, 1) <> '$'),
             (SELECT coalesce(sum(stream_version), 0) FROM streams WHERE substr(stream_id, 1, 1) <> '$'),
             (SELECT count(*) FROM archived_streams),
             (SELECT count(*) FROM streams WHERE substr(stream_id, 1, 1) = '$')
      """)

    %{
      streams: streams,
      events: events,
      all_position: system_stream_version("$all"),
      archived_streams: archived,
      system_streams: system,
      sync: sync_summary()
    }
  end

  defp system_stream_version(stream_id) do
    case query("SELECT stream_version FROM streams WHERE stream_id = ?1", [stream_id]) do
      [[version]] -> version
      [] -> 0
    end
  end

  defp sync_summary do
    state = State.load(RepoRead)

    if state.enabled do
      %{
        enabled: true,
        node_id: state.node_id,
        home: state.home,
        home?: State.home?(state),
        diverged: state.diverged,
        peers: state.peers |> Map.keys() |> Enum.sort(),
        assignments: map_size(state.owners)
      }
    else
      %{enabled: false}
    end
  end

  @doc """
  One page of streams.

  Options:

    * `:search` — only streams whose name contains this text;
    * `:sort` — `:name` (default), `:events` or `:created`;
    * `:order` — `:asc` (default) or `:desc`;
    * `:page` — 1-based (default 1);
    * `:per_page` — default #{@default_per_page};
    * `:system` — also list system streams such as `"$all"` (default `false`).

  Returns `%{entries, total, page, per_page, pages}`. Each entry has
  `stream_id`, `events` (the stream's event count, which is also its next
  version), `created_at`, `last_event_at`, `system?` and, when sync is
  enabled, `owner` as `{node_id, generation}`.
  """
  def streams(opts \\ []) do
    sort = Map.fetch!(@sorts, Keyword.get(opts, :sort, :name))
    order = if Keyword.get(opts, :order, :asc) == :desc, do: "DESC", else: "ASC"
    per_page = Keyword.get(opts, :per_page, @default_per_page)
    page = max(Keyword.get(opts, :page, 1), 1)
    system = if Keyword.get(opts, :system, false), do: 1, else: 0
    pattern = like_pattern(Keyword.get(opts, :search))

    where = """
    WHERE (?1 = 1 OR substr(s.stream_id, 1, 1) <> '$')
      AND (?2 IS NULL OR s.stream_id LIKE ?2 ESCAPE '\\')
    """

    [[total]] = query("SELECT count(*) FROM streams s " <> where, [system, pattern])

    rows =
      query(
        """
        SELECT s.stream_id, s.stream_version, s.inserted_at,
               (SELECT e.inserted_at FROM stream_events se JOIN events e ON e.id = se.event_id
                WHERE se.stream_id = s.stream_id ORDER BY se.stream_version DESC LIMIT 1)
        FROM streams s
        #{where}
        ORDER BY #{sort} #{order}, s.stream_id #{order}
        LIMIT ?3 OFFSET ?4
        """,
        [system, pattern, per_page, (page - 1) * per_page]
      )

    state = State.load(RepoRead)

    entries =
      Enum.map(rows, fn [stream_id, events, created_at, last_event_at] ->
        system? = String.starts_with?(stream_id, "$")

        %{
          stream_id: stream_id,
          events: events,
          created_at: created_at,
          last_event_at: last_event_at,
          system?: system?,
          owner: if(state.enabled and not system?, do: State.owner(state, stream_id))
        }
      end)

    %{entries: entries, total: total, page: page, per_page: per_page, pages: max(div(total + per_page - 1, per_page), 1)}
  end

  defp like_pattern(nil), do: nil
  defp like_pattern(""), do: nil

  defp like_pattern(search) do
    escaped = String.replace(search, ["\\", "%", "_"], &("\\" <> &1))
    "%" <> escaped <> "%"
  end

  defp query(sql, params \\ []), do: SQL.query!(RepoRead, sql, params).rows
end
