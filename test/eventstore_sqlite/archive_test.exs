defmodule EventstoreSqlite.ArchiveTest do
  use ExUnit.Case
  use EventstoreSqlite.DataCase
  use TypedStruct

  alias Ecto.Adapters.SQL
  alias EventstoreSqlite.RecordedEvent
  alias EventstoreSqlite.RepoWrite
  alias EventstoreSqlite.SystemEvents.StreamArchived

  typedstruct module: FooTestEvent do
    field(:text, :string)
  end

  defp event(text), do: %FooTestEvent{text: text}

  defp texts(events), do: Enum.map(events, & &1.data.text)

  defp query(sql, params \\ []), do: SQL.query!(RepoWrite, sql, params).rows

  defp archived_events do
    query("""
    SELECT a.stream_id, e.stream_version, e.all_position
    FROM archived_stream_events e JOIN archived_streams a ON a.id = e.archive_id
    ORDER BY e.archive_id, e.stream_version
    """)
  end

  defp snapshot do
    {query(
       "SELECT stream_id, stream_version, original_stream_id, original_stream_version FROM stream_events ORDER BY id"
     ), query("SELECT stream_id, stream_version FROM streams ORDER BY id"), query("SELECT * FROM archived_streams"),
     query("SELECT * FROM archived_stream_events"), query("SELECT count(*) FROM events")}
  end

  defp collect_messages(acc \\ []) do
    receive do
      message -> collect_messages([message | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end

  defp receive_events(count, received \\ [])

  defp receive_events(count, received) when length(received) >= count, do: received

  defp receive_events(count, received) do
    assert_receive {:events, events}
    receive_events(count, received ++ events)
  end

  describe "after archiving a stream" do
    setup do
      :ok = EventstoreSqlite.append_to_stream("ada", [event("a0"), event("a1")])
      :ok = EventstoreSqlite.append_to_stream("bob", [event("b0")])
      :ok = EventstoreSqlite.append_to_stream("ada", [event("a2")])

      assert :ok = EventstoreSqlite.archive_stream("ada")
      :ok
    end

    test "no read returns its events" do
      assert EventstoreSqlite.read_stream_forward("ada") == []
      assert EventstoreSqlite.read_stream_backward("ada") == []
      assert texts(EventstoreSqlite.read_stream_forward(["ada", "bob"])) == ["b0"]
      assert texts(EventstoreSqlite.read_stream_forward("$all")) == ["b0"]
    end

    test "list_streams doesn't list it, but lists $archives" do
      assert EventstoreSqlite.list_streams() == ["$all", "$archives", "bob"]
    end

    test "the name is free again and starts at version 0" do
      assert :ok = EventstoreSqlite.append_to_stream("ada", [event("new a0")], :no_stream)

      assert [%RecordedEvent{stream_version: 0, data: %{text: "new a0"}}] =
               EventstoreSqlite.read_stream_forward("ada")
    end

    test "the archive tables hold every event with its version and old $all position" do
      assert archived_events() == [["ada", 0, 0], ["ada", 1, 1], ["ada", 2, 3]]
      assert query("SELECT count(*) FROM events") == [[5]]
    end

    test "$all keeps its high-water mark, so the next append doesn't reuse a position" do
      :ok = EventstoreSqlite.append_to_stream("bob", [event("b1")])

      assert Enum.map(EventstoreSqlite.read_stream_forward("$all"), &{&1.stream_version, &1.data.text}) ==
               [{2, "b0"}, {4, "b1"}]
    end

    test "$archives holds a StreamArchived event and isn't part of $all" do
      [[archive_id]] = query("SELECT id FROM archived_streams")

      assert [
               %RecordedEvent{
                 stream_id: "$archives",
                 stream_version: 0,
                 type: "Elixir.EventstoreSqlite.SystemEvents.StreamArchived",
                 data: %StreamArchived{stream_id: "ada", archive_id: ^archive_id, event_count: 3}
               }
             ] = EventstoreSqlite.read_stream_forward("$archives")

      refute Enum.any?(EventstoreSqlite.read_stream_forward("$all"), &(&1.original_stream_id == "$archives"))
    end

    test "a rebuild of $all leaves out both the archived events and $archives" do
      assert {:ok, :done} = EventstoreSqlite.Migration.intial_fill_all()
      assert texts(EventstoreSqlite.read_stream_forward("$all")) == ["b0"]

      assert :ok = EventstoreSqlite.append_to_stream("bob", [event("b1")])
      assert texts(EventstoreSqlite.read_stream_forward("$all")) == ["b0", "b1"]
    end
  end

  test "a reused name can be archived again, and both archives are complete" do
    :ok = EventstoreSqlite.append_to_stream("ada", [event("a0"), event("a1")])
    :ok = EventstoreSqlite.archive_stream("ada")
    :ok = EventstoreSqlite.append_to_stream("ada", [event("new a0")])
    :ok = EventstoreSqlite.archive_stream("ada")

    assert archived_events() == [["ada", 0, 0], ["ada", 1, 1], ["ada", 0, 2]]

    assert [%{data: %{event_count: 2}}, %{data: %{event_count: 1}}] =
             EventstoreSqlite.read_stream_forward("$archives")
  end

  test "archiving a stream whose events are spread over large appends" do
    :ok = EventstoreSqlite.append_to_stream("ada", Enum.map(1..2_500, &event("a#{&1}")))
    :ok = EventstoreSqlite.append_to_stream("bob", [event("b0")])

    assert :ok = EventstoreSqlite.archive_stream("ada", {:version, 2_500})
    assert query("SELECT count(*) FROM archived_stream_events") == [[2_500]]
    assert texts(EventstoreSqlite.read_stream_forward("$all")) == ["b0"]
  end

  describe "refused archives write nothing" do
    test "a wrong expected version" do
      :ok = EventstoreSqlite.append_to_stream("ada", [event("a0")])
      before = snapshot()

      assert {:error, :wrong_expected_version} = EventstoreSqlite.archive_stream("ada", {:version, 5})
      assert {:error, :wrong_expected_version} = EventstoreSqlite.archive_stream("ada", :no_stream)
      assert snapshot() == before

      assert :ok = EventstoreSqlite.archive_stream("ada", {:version, 1})
    end

    test "a stream that doesn't exist, or is already archived" do
      assert {:error, :stream_not_found} = EventstoreSqlite.archive_stream("ada")

      :ok = EventstoreSqlite.append_to_stream("ada", [event("a0")])
      :ok = EventstoreSqlite.archive_stream("ada")
      before = snapshot()

      assert {:error, :stream_not_found} = EventstoreSqlite.archive_stream("ada")
      assert snapshot() == before
    end

    test "the system streams" do
      :ok = EventstoreSqlite.append_to_stream("ada", [event("a0")])
      :ok = EventstoreSqlite.archive_stream("ada")
      before = snapshot()

      assert {:error, :system_stream} = EventstoreSqlite.archive_stream("$all")
      assert {:error, :system_stream} = EventstoreSqlite.archive_stream("$archives")
      assert snapshot() == before
    end

    test "appending to $archives" do
      assert {:error, :system_stream} = EventstoreSqlite.append_to_stream("$archives", [event("x")])
      assert EventstoreSqlite.list_streams() == []
    end
  end

  describe "a stream whose $all rows don't match its events" do
    setup do
      :ok = EventstoreSqlite.append_to_stream("ada", [event("a0"), event("a1")])
      subscriptions = Process.whereis(EventstoreSqlite.Subscriptions)
      {:ok, subscriptions: subscriptions}
    end

    test "can't be archived when an event has no $all row", %{subscriptions: subscriptions} do
      query("DELETE FROM stream_events WHERE stream_id = '$all' AND original_stream_version = 0")
      before = snapshot()

      error = assert_raise RuntimeError, fn -> EventstoreSqlite.archive_stream("ada") end

      assert error.message =~ ~s(cannot archive "ada": its version is 2, but it has 2 rows and 1 rows in $all)
      assert snapshot() == before
      assert Process.whereis(EventstoreSqlite.Subscriptions) == subscriptions
    end

    test "can't be archived when an event has two $all rows" do
      query("""
      INSERT INTO stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version)
      SELECT event_id, '$all', 99, original_stream_id, original_stream_version
      FROM stream_events WHERE stream_id = '$all' AND original_stream_version = 0
      """)

      before = snapshot()

      error = assert_raise RuntimeError, fn -> EventstoreSqlite.archive_stream("ada") end

      assert error.message =~ "2 rows and 3 rows in $all"
      assert snapshot() == before
    end
  end

  describe "subscriptions" do
    test "subscribers of the stream are told and their subscription ends" do
      :ok = EventstoreSqlite.append_to_stream("ada", [event("a0")])
      :ok = EventstoreSqlite.subscribe_to_stream(self(), "ada")
      assert texts(receive_events(1)) == ["a0"]

      :ok = EventstoreSqlite.archive_stream("ada")
      assert_receive {:stream_archived, "ada"}

      :ok = EventstoreSqlite.append_to_stream("ada", [event("new a0")])
      assert collect_messages() == []

      :ok = EventstoreSqlite.subscribe_to_stream(self(), "ada")
      assert [%RecordedEvent{stream_version: 0, data: %{text: "new a0"}}] = receive_events(1)
    end

    test "a subscriber of $archives receives the StreamArchived event right away" do
      :ok = EventstoreSqlite.append_to_stream("ada", [event("a0")])
      :ok = EventstoreSqlite.subscribe_to_stream(self(), "$archives")

      :ok = EventstoreSqlite.archive_stream("ada")

      assert [%RecordedEvent{data: %StreamArchived{stream_id: "ada", event_count: 1}}] = receive_events(1)
    end

    test "a $all subscriber keeps working across the gap" do
      :ok = EventstoreSqlite.append_to_stream("ada", [event("a0")])
      :ok = EventstoreSqlite.append_to_stream("bob", [event("b0")])
      :ok = EventstoreSqlite.subscribe_to_stream(self(), "$all")
      :ok = EventstoreSqlite.subscribe_to_stream(self(), "ada")
      assert length(receive_events(3)) == 3

      :ok = EventstoreSqlite.archive_stream("ada")
      assert_receive {:stream_archived, "ada"}
      :ok = EventstoreSqlite.append_to_stream("bob", [event("b1")])

      assert [%RecordedEvent{stream_version: 2, data: %{text: "b1"}}] = receive_events(1)
    end

    test "appends racing the archive never reach the old subscriber, and the new stream starts at 0" do
      :ok = EventstoreSqlite.append_to_stream("ada", [event("old")])
      :ok = EventstoreSqlite.subscribe_to_stream(self(), "ada")
      assert texts(receive_events(1)) == ["old"]

      appender =
        Task.async(fn ->
          for n <- 1..40, do: :ok = EventstoreSqlite.append_to_stream("ada", [event("racing #{n}")])
        end)

      Process.sleep(5)
      :ok = EventstoreSqlite.archive_stream("ada")
      Task.await(appender)

      messages = collect_messages()

      {before_archive, [{:stream_archived, "ada"} | after_archive]} =
        Enum.split_while(messages, &match?({:events, _}, &1))

      archived_ids = MapSet.new(query("SELECT event_id FROM archived_stream_events"), fn [id] -> id end)
      delivered = Enum.flat_map(before_archive, fn {:events, events} -> events end)

      assert after_archive == []
      assert Enum.all?(delivered, &MapSet.member?(archived_ids, &1.id))

      live = EventstoreSqlite.read_stream_forward("ada")
      :ok = EventstoreSqlite.subscribe_to_stream(self(), "ada")
      received = receive_events(length(live))

      assert Enum.map(received, & &1.stream_version) == Enum.to_list(0..(length(live) - 1)//1)
      assert texts(received) == texts(live)
      assert MapSet.size(archived_ids) + length(live) == 41
    end
  end

  describe "the CreateArchiveTables migration" do
    setup do
      previous = Code.get_compiler_option(:ignore_module_conflict)
      Code.put_compiler_option(:ignore_module_conflict, true)

      on_exit(fn ->
        query("DELETE FROM stream_events WHERE stream_id = '$archives'")
        query("DELETE FROM streams WHERE stream_id = '$archives'")
        Ecto.Migrator.run(RepoWrite, Ecto.Migrator.migrations_path(RepoWrite), :up, all: true, log: false)
        EventstoreSqlite.DataCase.reset!()
        Code.put_compiler_option(:ignore_module_conflict, previous)
      end)
    end

    test "refuses to take over an existing $archives stream" do
      Ecto.Migrator.run(RepoWrite, Ecto.Migrator.migrations_path(RepoWrite), :down, to: 20_261_002_130_000, log: false)
      query("INSERT INTO streams (stream_id, stream_version, inserted_at) VALUES ('$archives', 0, '2026-10-02T00:00:00')")

      error =
        assert_raise RuntimeError, fn ->
          Ecto.Migrator.run(RepoWrite, Ecto.Migrator.migrations_path(RepoWrite), :up, all: true, log: false)
        end

      assert error.message =~ ~s|A stream named "$archives" already exists (0 events)|
      assert query("SELECT name FROM sqlite_master WHERE name LIKE 'archived_%'") == []
    end

    test "can't be rolled back once a stream is archived" do
      :ok = EventstoreSqlite.append_to_stream("ada", [event("a0")])
      :ok = EventstoreSqlite.archive_stream("ada")

      error =
        assert_raise RuntimeError, fn ->
          Ecto.Migrator.run(RepoWrite, Ecto.Migrator.migrations_path(RepoWrite), :down,
            to: 20_261_002_130_000,
            log: false
          )
        end

      assert error.message =~ "Refusing to drop the archive tables: they hold 1 archived streams"
      assert archived_events() == [["ada", 0, 0]]
    end

    test "can be rolled back before anything is archived" do
      Ecto.Migrator.run(RepoWrite, Ecto.Migrator.migrations_path(RepoWrite), :down, to: 20_261_002_130_000, log: false)

      assert query("SELECT name FROM sqlite_master WHERE name LIKE 'archived_%'") == []
    end
  end
end
