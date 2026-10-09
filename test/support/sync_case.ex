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
