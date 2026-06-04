defmodule EventstoreSqlite.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Because the read and write repos share a single SQLite file, writes must be
  committed (not held in a rolled-back transaction) for reads to see them, so the
  Ecto SQL sandbox does not fit. Instead, every test starts from an empty schema:
  `reset!/0` truncates all tables before each test. Tests therefore run
  synchronously (`async: true` is not supported).

  The `events` table is immutable in production via a BEFORE-DELETE trigger. To
  keep the test schema identical, `reset!/0` only drops that guard for the
  instant it takes to truncate `events`, then reinstalls the exact definition it
  read back from the schema, so test bodies still run against the real, immutable
  schema and the trigger never drifts from the migration.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL

  using do
    quote do
      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import EventstoreSqlite.DataCase
    end
  end

  setup _tags do
    EventstoreSqlite.DataCase.reset!()
    :ok
  end

  @doc """
  Truncates all tables so each test starts from an empty schema.

  Deletes the child table (`stream_events`) before its parents to stay
  foreign-key safe. The `events` table's BEFORE-DELETE guard is dropped only for
  the duration of its truncation and then reinstalled from its own definition (as
  stored in `sqlite_master`), so it stays in force for every test body without
  the reset hardcoding any trigger SQL.
  """
  def reset! do
    repo = EventstoreSqlite.RepoWrite

    SQL.query!(repo, "DELETE FROM stream_events", [])
    truncate_events(repo)
    SQL.query!(repo, "DELETE FROM streams", [])

    :ok
  end

  defp truncate_events(repo) do
    query = "SELECT sql FROM sqlite_master WHERE type = 'trigger' AND name = 'no_delete_events'"

    case SQL.query!(repo, query, []) do
      %{rows: [[trigger_sql]]} ->
        SQL.query!(repo, "DROP TRIGGER no_delete_events", [])
        SQL.query!(repo, "DELETE FROM events", [])
        SQL.query!(repo, trigger_sql, [])

      %{rows: []} ->
        SQL.query!(repo, "DELETE FROM events", [])
    end
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
