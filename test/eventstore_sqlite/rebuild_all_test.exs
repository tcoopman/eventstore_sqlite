defmodule EventstoreSqlite.RebuildAllTest do
  use ExUnit.Case
  use EventstoreSqlite.DataCase
  use TypedStruct

  alias Ecto.Adapters.SQL
  alias EventstoreSqlite.Migration
  alias EventstoreSqlite.RepoWrite

  typedstruct module: FooTestEvent do
    field(:text, :string)
  end

  defp event(text), do: %FooTestEvent{text: text}

  defp all_events do
    "$all"
    |> EventstoreSqlite.read_stream_forward(count: nil)
    |> Enum.map(&{&1.stream_version, &1.original_stream_id, &1.original_stream_version, &1.data.text})
  end

  defp all_high_water_mark do
    %{rows: rows} = SQL.query!(RepoWrite, "SELECT stream_version FROM streams WHERE stream_id = '$all'")

    case rows do
      [[version]] -> version
      [] -> nil
    end
  end

  defp remove_all do
    SQL.query!(RepoWrite, "DELETE FROM stream_events WHERE stream_id = '$all'")
    SQL.query!(RepoWrite, "DELETE FROM streams WHERE stream_id = '$all'")
  end

  defp leave_gaps_in_all do
    SQL.query!(RepoWrite, "DELETE FROM stream_events WHERE stream_id = '$all'")

    SQL.query!(RepoWrite, """
    INSERT INTO stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version)
    SELECT event_id, '$all', 10 * (row_number() OVER (ORDER BY id)), stream_id, stream_version
    FROM stream_events
    ORDER BY id
    """)
  end

  test "an append after a rebuild gets the next position" do
    :ok = EventstoreSqlite.append_to_stream("ada", [event("a0"), event("a1")])
    :ok = EventstoreSqlite.append_to_stream("bob", [event("b0")])

    assert {:ok, :done} = Migration.intial_fill_all()
    assert :ok = EventstoreSqlite.append_to_stream("ada", [event("a2")])

    assert all_events() == [
             {0, "ada", 0, "a0"},
             {1, "ada", 1, "a1"},
             {2, "bob", 0, "b0"},
             {3, "ada", 2, "a2"}
           ]
  end

  test "a rebuild numbers $all densely in append order" do
    :ok = EventstoreSqlite.append_to_stream("bob", [event("b0")])
    :ok = EventstoreSqlite.append_to_stream("ada", [event("a0")])
    :ok = EventstoreSqlite.append_to_stream("bob", [event("b1")])
    leave_gaps_in_all()

    assert {:ok, :done} = Migration.intial_fill_all()

    assert all_events() == [
             {0, "bob", 0, "b0"},
             {1, "ada", 0, "a0"},
             {2, "bob", 1, "b1"}
           ]

    assert all_high_water_mark() == 3
  end

  test "a rebuild follows append order even when event ids don't" do
    later_id = "ffffffff-ffff-7fff-bfff-ffffffffffff"
    earlier_id = "00000000-0000-7000-8000-000000000000"

    :ok = EventstoreSqlite.append_to_stream("ada", [%EventstoreSqlite.NewEvent{id: later_id, data: event("first")}])
    :ok = EventstoreSqlite.append_to_stream("ada", [%EventstoreSqlite.NewEvent{id: earlier_id, data: event("second")}])

    assert {:ok, :done} = Migration.intial_fill_all()

    assert all_events() == [{0, "ada", 0, "first"}, {1, "ada", 1, "second"}]
  end

  test "a rebuild creates $all when the store never had it" do
    :ok = EventstoreSqlite.append_to_stream("ada", [event("a0"), event("a1")])
    remove_all()

    assert {:ok, :done} = Migration.intial_fill_all()
    assert all_high_water_mark() == 2

    assert :ok = EventstoreSqlite.append_to_stream("ada", [event("a2")])
    assert all_events() == [{0, "ada", 0, "a0"}, {1, "ada", 1, "a1"}, {2, "ada", 2, "a2"}]
  end

  test "a rebuild of an empty store succeeds" do
    assert {:ok, :done} = Migration.intial_fill_all()
    assert all_high_water_mark() == 0

    assert :ok = EventstoreSqlite.append_to_stream("ada", [event("a0")])
    assert all_events() == [{0, "ada", 0, "a0"}]
  end

  test "a rebuild succeeds when $all exists but no stream has events" do
    :ok = EventstoreSqlite.append_to_stream("ada", [event("a0")])
    SQL.query!(RepoWrite, "DELETE FROM stream_events")

    assert {:ok, :done} = Migration.intial_fill_all()
    assert all_high_water_mark() == 0
    assert all_events() == []
  end
end
