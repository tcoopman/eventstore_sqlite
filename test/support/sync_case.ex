defmodule EventstoreSqlite.Test.Note do
  @moduledoc false
  use TypedStruct

  typedstruct do
    field(:text, String.t())
  end
end

defmodule EventstoreSqlite.SyncCase do
  @moduledoc """
  Helpers for single-node sync tests. The test config names this node
  `"test-node"`.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL
  alias EventstoreSqlite.RepoWrite
  alias EventstoreSqlite.Sync.State

  using do
    quote do
      import EventstoreSqlite.SyncCase

      alias EventstoreSqlite.Sync
      alias EventstoreSqlite.Sync.State
      alias EventstoreSqlite.SystemEvents
      alias EventstoreSqlite.Test.Note
    end
  end

  def note(text), do: %EventstoreSqlite.Test.Note{text: text}

  def notes(count, prefix \\ "n"), do: Enum.map(1..count, &note("#{prefix}#{&1}"))

  def query(sql, params \\ []), do: SQL.query!(RepoWrite, sql, params).rows

  @doc """
  Records system events as if they had happened on this node, and persists the
  resulting state.
  """
  def record!(events) do
    {:ok, state} =
      RepoWrite.transact(
        fn repo ->
          state = Enum.reduce(List.wrap(events), State.load(repo), &State.record(repo, &2, &1))
          {:ok, State.save(repo, state)}
        end,
        mode: :immediate
      )

    state
  end

  def log_rows do
    query("SELECT seq, kind, stream_id, stream_version, generation FROM sync_log ORDER BY seq")
  end

  def log_event_ids(seq) do
    "SELECT event_id FROM sync_log_events WHERE seq = ?1 ORDER BY position" |> query([seq]) |> List.flatten()
  end
end

defmodule EventstoreSqlite.SyncEntries do
  @moduledoc """
  Builds log entries as another node would export them.
  """

  def raw_event(text, opts \\ []) do
    %{
      id: Keyword.get(opts, :id, Ecto.UUID.generate()),
      type: "Elixir.EventstoreSqlite.Test.Note",
      data: :erlang.term_to_binary(%EventstoreSqlite.Test.Note{text: text}),
      metadata: Keyword.get(opts, :metadata),
      inserted_at: "2026-10-01T10:00:00Z"
    }
  end

  def append_entry(seq, stream_id, version, texts, generation \\ 0) do
    %{
      seq: seq,
      kind: :append,
      stream_id: stream_id,
      stream_version: version,
      generation: generation,
      payload: nil,
      events: Enum.map(List.wrap(texts), &raw_event/1)
    }
  end

  def archive_entry(seq, stream_id, event_count, generation \\ 0) do
    %{
      seq: seq,
      kind: :archive,
      stream_id: stream_id,
      stream_version: event_count,
      generation: generation,
      payload: nil,
      events: []
    }
  end

  def ownership_entry(seq, payload) do
    %{seq: seq, kind: :ownership, stream_id: nil, stream_version: nil, generation: nil, payload: payload, events: []}
  end
end
