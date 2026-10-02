defmodule EventstoreSqlite.OriginalStreamTest do
  use ExUnit.Case
  use EventstoreSqlite.DataCase
  use TypedStruct

  alias Ecto.Adapters.SQL
  alias EventstoreSqlite.RecordedEvent
  alias EventstoreSqlite.RepoWrite

  typedstruct module: FooTestEvent do
    field(:text, :string)
  end

  defp event(text), do: %FooTestEvent{text: text}

  defp origins(events) do
    Enum.map(events, &{&1.stream_id, &1.stream_version, &1.original_stream_id, &1.original_stream_version})
  end

  defp all_rows do
    %{rows: rows} =
      SQL.query!(
        RepoWrite,
        "SELECT stream_version, original_stream_id, original_stream_version FROM stream_events WHERE stream_id = '$all' ORDER BY stream_version"
      )

    rows
  end

  defp rewrite_all_rows_the_old_way do
    SQL.query!(RepoWrite, "DELETE FROM stream_events WHERE stream_id = '$all'")

    SQL.query!(RepoWrite, """
    INSERT INTO stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version)
    SELECT event_id, '$all', row_number() OVER (ORDER BY id) - 1, '$all', row_number() OVER (ORDER BY id) - 1
    FROM stream_events
    WHERE stream_id <> '$all'
    ORDER BY id
    """)
  end

  defp fill_all_origins do
    RepoWrite.transact(fn repo -> {:ok, EventstoreSqlite.Migration.fill_all_origins(repo)} end)
  end

  defp receive_events(count, received \\ [])

  defp receive_events(count, received) when length(received) >= count, do: received

  defp receive_events(count, received) do
    assert_receive {:events, events}
    receive_events(count, received ++ events)
  end

  @fill_all_origins_version 20_261_002_120_000

  defp migrate(direction) do
    path = Ecto.Migrator.migrations_path(RepoWrite)

    case direction do
      :down -> Ecto.Migrator.run(RepoWrite, path, :down, to: @fill_all_origins_version, log: false)
      :up -> Ecto.Migrator.run(RepoWrite, path, :up, all: true, log: false)
    end
  end

  defp origin_index_installed? do
    %{rows: rows} =
      SQL.query!(
        RepoWrite,
        "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = 'stream_events_original_stream_id_original_stream_version_index'"
      )

    rows == [[1]]
  end

  defp temporary_index_left? do
    %{rows: rows} =
      SQL.query!(
        RepoWrite,
        "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = 'stream_events_fill_all_origins_event_id_index'"
      )

    rows != []
  end

  defp update_guard_installed? do
    %{rows: rows} =
      SQL.query!(RepoWrite, "SELECT 1 FROM sqlite_master WHERE type = 'trigger' AND name = 'no_update_stream_events'")

    rows == [[1]]
  end

  describe "reading" do
    test "events read from $all carry the stream and version they were appended to" do
      :ok = EventstoreSqlite.append_to_stream("ada", [event("a0"), event("a1")])
      :ok = EventstoreSqlite.append_to_stream("bob", [event("b0")])
      :ok = EventstoreSqlite.append_to_stream("ada", [event("a2")])

      assert origins(EventstoreSqlite.read_stream_forward("$all")) == [
               {"$all", 0, "ada", 0},
               {"$all", 1, "ada", 1},
               {"$all", 2, "bob", 0},
               {"$all", 3, "ada", 2}
             ]
    end

    test "events read from their own stream are their own origin" do
      :ok = EventstoreSqlite.append_to_stream("bob", [event("b0")])
      :ok = EventstoreSqlite.append_to_stream("ada", [event("a0"), event("a1")])

      assert origins(EventstoreSqlite.read_stream_backward("ada")) == [
               {"ada", 1, "ada", 1},
               {"ada", 0, "ada", 0}
             ]
    end

    test "a row with NULL origin columns reads back as its own origin" do
      :ok = EventstoreSqlite.append_to_stream("ada", [event("a0")])
      SQL.query!(RepoWrite, "DELETE FROM stream_events WHERE stream_id = 'ada'")

      SQL.query!(RepoWrite, """
      INSERT INTO stream_events (event_id, stream_id, stream_version)
      SELECT event_id, 'ada', 0 FROM stream_events WHERE stream_id = '$all'
      """)

      assert origins(EventstoreSqlite.read_stream_forward("ada")) == [{"ada", 0, "ada", 0}]
    end

    test "a $all subscriber receives the origin of each event" do
      :ok = EventstoreSqlite.subscribe_to_stream(self(), "$all")
      :ok = EventstoreSqlite.append_to_stream("ada", [event("a0")])
      :ok = EventstoreSqlite.append_to_stream("bob", [event("b0")])

      assert [
               %RecordedEvent{original_stream_id: "ada", original_stream_version: 0},
               %RecordedEvent{original_stream_id: "bob", original_stream_version: 0}
             ] = receive_events(2)
    end
  end

  describe "appending to $all" do
    test "is refused for every expected version and writes nothing" do
      for expected_version <- [:any_version, :no_stream, :stream_exists, {:version, 0}] do
        assert {:error, :system_stream} = EventstoreSqlite.append_to_stream("$all", [event("x")], expected_version)
        assert {:error, :system_stream} = EventstoreSqlite.append_to_stream("$all", [], expected_version)
      end

      assert EventstoreSqlite.read_stream_forward("$all") == []
      assert EventstoreSqlite.list_streams() == []
    end
  end

  describe "Migration.fill_all_origins/1" do
    test "points $all rows written the old way at their stream" do
      :ok = EventstoreSqlite.append_to_stream("ada", [event("a0"), event("a1")])
      :ok = EventstoreSqlite.append_to_stream("bob", [event("b0")])
      rewrite_all_rows_the_old_way()

      assert all_rows() == [[0, "$all", 0], [1, "$all", 1], [2, "$all", 2]]

      assert {:ok, :ok} = fill_all_origins()

      assert all_rows() == [[0, "ada", 0], [1, "ada", 1], [2, "bob", 0]]
      refute temporary_index_left?()
    end

    test "keeps stream_events immutable afterwards" do
      :ok = EventstoreSqlite.append_to_stream("ada", [event("a0")])

      assert {:ok, :ok} = fill_all_origins()

      assert update_guard_installed?()

      assert_raise Exqlite.Error, ~r/cannot update stream_events/, fn ->
        SQL.query!(RepoWrite, "UPDATE stream_events SET stream_version = 9")
      end
    end

    test "succeeds on an empty store" do
      assert {:ok, :ok} = fill_all_origins()
      assert update_guard_installed?()
    end

    test "aborts without changing anything when a $all row has no stream row" do
      :ok = EventstoreSqlite.append_to_stream("ada", [event("a0"), event("a1")])
      rewrite_all_rows_the_old_way()
      SQL.query!(RepoWrite, "DELETE FROM stream_events WHERE stream_id = 'ada' AND stream_version = 0")

      error = assert_raise RuntimeError, fn -> fill_all_origins() end

      assert error.message =~ "1 $all rows have no original stream and 0 have more than one"
      assert error.message =~ "WHERE original_streams <> 1"
      assert all_rows() == [[0, "$all", 0], [1, "$all", 1]]
      assert update_guard_installed?()
    end

    test "aborts without changing anything when an event is in two streams" do
      :ok = EventstoreSqlite.append_to_stream("ada", [event("a0")])
      :ok = EventstoreSqlite.append_to_stream("bob", [event("b0")])
      rewrite_all_rows_the_old_way()

      SQL.query!(RepoWrite, """
      INSERT INTO stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version)
      SELECT event_id, 'bob', 1, 'bob', 1 FROM stream_events WHERE stream_id = 'ada'
      """)

      error = assert_raise RuntimeError, fn -> fill_all_origins() end

      assert error.message =~ "0 $all rows have no original stream and 1 have more than one"
      assert all_rows() == [[0, "$all", 0], [1, "$all", 1]]
      assert update_guard_installed?()
    end
  end

  describe "the FillAllOrigins migration" do
    setup do
      previous = Code.get_compiler_option(:ignore_module_conflict)
      Code.put_compiler_option(:ignore_module_conflict, true)

      on_exit(fn ->
        EventstoreSqlite.DataCase.reset!()
        migrate(:up)
        Code.put_compiler_option(:ignore_module_conflict, previous)
      end)
    end

    test "fixes existing $all rows and adds the origin index" do
      :ok = EventstoreSqlite.append_to_stream("ada", [event("a0")])
      :ok = EventstoreSqlite.append_to_stream("bob", [event("b0")])
      migrate(:down)
      rewrite_all_rows_the_old_way()

      refute origin_index_installed?()

      migrate(:up)

      assert all_rows() == [[0, "ada", 0], [1, "bob", 0]]
      assert origin_index_installed?()
      assert update_guard_installed?()
      refute temporary_index_left?()
    end

    test "rolls back completely when a $all row has no stream row" do
      :ok = EventstoreSqlite.append_to_stream("ada", [event("a0"), event("a1")])
      migrate(:down)
      rewrite_all_rows_the_old_way()
      SQL.query!(RepoWrite, "DELETE FROM stream_events WHERE stream_id = 'ada' AND stream_version = 0")

      assert_raise RuntimeError, ~r/cannot fill the origin of the \$all events/, fn -> migrate(:up) end

      assert all_rows() == [[0, "$all", 0], [1, "$all", 1]]
      refute origin_index_installed?()
      refute temporary_index_left?()
      assert update_guard_installed?()
    end
  end
end
