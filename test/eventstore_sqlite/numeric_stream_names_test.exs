defmodule EventstoreSqlite.NumericStreamNamesTest do
  use ExUnit.Case
  use EventstoreSqlite.DataCase
  use TypedStruct

  alias Ecto.Adapters.SQL
  alias EventstoreSqlite.RecordedEvent
  alias EventstoreSqlite.RepoWrite

  typedstruct module: FooTestEvent do
    field(:text, :string)
  end

  @names ["123", "-5", "1.5", "007", "1e3", " 42", "99999999999999999999", "abc"]
  @text_stream_ids_version 20_261_002_140_000

  defp event(text), do: %FooTestEvent{text: text}

  defp query(sql, params \\ []), do: SQL.query!(RepoWrite, sql, params).rows

  defp migrate(direction) do
    path = Ecto.Migrator.migrations_path(RepoWrite)

    case direction do
      :down -> Ecto.Migrator.run(RepoWrite, path, :down, to: @text_stream_ids_version, log: false)
      :up -> Ecto.Migrator.run(RepoWrite, path, :up, all: true, log: false)
    end
  end

  defp schema_objects do
    query("SELECT type, name, sql FROM sqlite_master WHERE tbl_name = 'stream_events' ORDER BY type, name")
  end

  defp stored_stream_ids do
    query(
      "SELECT stream_id, typeof(stream_id), original_stream_id, typeof(original_stream_id) FROM stream_events ORDER BY id"
    )
  end

  defp receive_events(count, received \\ [])

  defp receive_events(count, received) when length(received) >= count, do: received

  defp receive_events(count, received) do
    assert_receive {:events, events}
    receive_events(count, received ++ events)
  end

  test "numeric-looking names can be appended, and read back as the same strings" do
    for name <- @names do
      assert :ok = EventstoreSqlite.append_to_stream(name, [event(name)], :no_stream)

      assert [%RecordedEvent{stream_id: ^name, original_stream_id: ^name, stream_version: 0}] =
               EventstoreSqlite.read_stream_forward(name)
    end

    assert Enum.map(EventstoreSqlite.read_stream_forward("$all"), & &1.original_stream_id) == @names
    assert EventstoreSqlite.list_streams() == Enum.sort(["$all" | @names])
  end

  test "subscribers of a numeric-looking name receive it as a string" do
    :ok = EventstoreSqlite.subscribe_to_stream(self(), "123")
    :ok = EventstoreSqlite.subscribe_to_stream(self(), "007")
    :ok = EventstoreSqlite.append_to_stream("123", [event("a")])
    :ok = EventstoreSqlite.append_to_stream("007", [event("b")])

    assert Enum.map(receive_events(2), &{&1.stream_id, &1.data.text}) == [{"123", "a"}, {"007", "b"}]
  end

  test "numeric-looking names can be archived" do
    :ok = EventstoreSqlite.append_to_stream("007", [event("a")])

    assert :ok = EventstoreSqlite.archive_stream("007")
    assert EventstoreSqlite.read_stream_forward("007") == []
    assert query("SELECT stream_id FROM archived_streams") == [["007"]]
  end

  describe "the TextStreamIds migration" do
    setup do
      previous = Code.get_compiler_option(:ignore_module_conflict)
      Code.put_compiler_option(:ignore_module_conflict, true)

      on_exit(fn ->
        migrate(:up)
        EventstoreSqlite.DataCase.reset!()
        Code.put_compiler_option(:ignore_module_conflict, previous)
      end)
    end

    test "turns stream ids stored as numbers back into the stream names" do
      objects = schema_objects()
      migrate(:down)

      :ok = EventstoreSqlite.append_to_stream("123", [event("a")])
      :ok = EventstoreSqlite.append_to_stream("abc", [event("b")])
      :ok = EventstoreSqlite.append_to_stream("1.5", [event("c")])

      assert stored_stream_ids() == [
               [123, "integer", 123, "integer"],
               ["$all", "text", 123, "integer"],
               ["abc", "text", "abc", "text"],
               ["$all", "text", "abc", "text"],
               [1.5, "real", 1.5, "real"],
               ["$all", "text", 1.5, "real"]
             ]

      ids = query("SELECT id FROM stream_events ORDER BY id")
      migrate(:up)

      assert stored_stream_ids() == [
               ["123", "text", "123", "text"],
               ["$all", "text", "123", "text"],
               ["abc", "text", "abc", "text"],
               ["$all", "text", "abc", "text"],
               ["1.5", "text", "1.5", "text"],
               ["$all", "text", "1.5", "text"]
             ]

      assert query("SELECT id FROM stream_events ORDER BY id") == ids
      assert schema_objects() == objects
      assert query("PRAGMA foreign_key_check") == []

      assert_raise Exqlite.Error, ~r/cannot update stream_events/, fn ->
        query("UPDATE stream_events SET stream_version = 9")
      end

      assert Enum.map(EventstoreSqlite.read_stream_forward(["123", "abc", "1.5"]), & &1.stream_id) == [
               "123",
               "abc",
               "1.5"
             ]
    end

    test "keeps the id counter, so ids of deleted rows aren't reused" do
      :ok = EventstoreSqlite.append_to_stream("ada", [event("a0"), event("a1")])
      :ok = EventstoreSqlite.archive_stream("ada")
      [[highest_id]] = query("SELECT seq FROM sqlite_sequence WHERE name = 'stream_events'")

      migrate(:down)
      migrate(:up)

      :ok = EventstoreSqlite.append_to_stream("bob", [event("b0")])
      [[next_id]] = query("SELECT min(id) FROM stream_events WHERE stream_id = 'bob'")

      assert next_id > highest_id
    end

    test "can't be rolled back while a stream has a name INTEGER columns would change" do
      :ok = EventstoreSqlite.append_to_stream("007", [event("a")])
      objects = schema_objects()

      error = assert_raise RuntimeError, fn -> migrate(:down) end

      assert error.message =~ ~s(cannot rebuild stream_events with INTEGER stream ids)
      assert error.message =~ "Nothing was changed"
      assert schema_objects() == objects
      assert [%RecordedEvent{stream_id: "007"}] = EventstoreSqlite.read_stream_forward("007")
    end

    test "works on an empty store" do
      objects = schema_objects()

      migrate(:down)
      migrate(:up)

      assert schema_objects() == objects
      assert :ok = EventstoreSqlite.append_to_stream("007", [event("a")])
    end
  end
end
