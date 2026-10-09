defmodule EventstoreSqlite.StreamInfoTest do
  use ExUnit.Case
  use EventstoreSqlite.DataCase
  use EventstoreSqlite.SyncCase

  alias EventstoreSqlite.StreamInfo

  defp names(%{entries: entries}), do: Enum.map(entries, & &1.stream_id)

  describe "stream_info/1" do
    test "has the version and the times of the first and last event" do
      :ok = EventstoreSqlite.append_to_stream("orders:1", notes(3))

      assert {:ok, %StreamInfo{stream_id: "orders:1", version: 3, owner: nil} = info} =
               EventstoreSqlite.stream_info("orders:1")

      assert %DateTime{} = info.created_at
      assert DateTime.compare(info.created_at, info.last_event_at) in [:lt, :eq]
    end

    test "the times are the events' own" do
      :ok = EventstoreSqlite.append_to_stream("orders:1", notes(2))
      [first, last] = EventstoreSqlite.read_stream_forward("orders:1")

      assert {:ok, %{created_at: created_at, last_event_at: last_event_at}} = EventstoreSqlite.stream_info("orders:1")
      assert created_at == first.created_at
      assert last_event_at == last.created_at
    end

    test "a missing or archived stream is not found" do
      assert EventstoreSqlite.stream_info("nope") == {:error, :not_found}

      :ok = EventstoreSqlite.append_to_stream("gone", notes(1))
      :ok = EventstoreSqlite.archive_stream("gone")
      assert EventstoreSqlite.stream_info("gone") == {:error, :not_found}
    end

    test "a new stream after an archive starts over" do
      :ok = EventstoreSqlite.append_to_stream("again", notes(4))
      :ok = EventstoreSqlite.archive_stream("again")
      :ok = EventstoreSqlite.append_to_stream("again", notes(1))

      assert {:ok, %{version: 1}} = EventstoreSqlite.stream_info("again")
    end

    test "system streams have info, without an owner" do
      :ok = Sync.enable("test-node")
      :ok = EventstoreSqlite.append_to_stream("orders:1", notes(2))

      assert {:ok, %{version: 2, owner: nil}} = EventstoreSqlite.stream_info("$all")
      assert {:ok, %{owner: {"test-node", 0}}} = EventstoreSqlite.stream_info("orders:1")
    end

    test "owners follow assignments" do
      :ok = Sync.enable("test-node")
      record!(%SystemEvents.PeerAdded{node_id: "peer", pinned_seq: 0})
      :ok = EventstoreSqlite.append_to_stream("orders:1", notes(1))
      :ok = EventstoreSqlite.append_to_stream("venue:1", notes(1))

      {:ok, generation} = EventstoreSqlite.Ownership.assign("venue:*", "peer")

      assert {:ok, %{owner: {"test-node", 0}}} = EventstoreSqlite.stream_info("orders:1")
      assert {:ok, %{owner: {"peer", ^generation}}} = EventstoreSqlite.stream_info("venue:1")
    end
  end

  describe "list_stream_infos/1" do
    setup do
      for name <- ["b", "a", "c:100%_off", "d", "e"], do: :ok = EventstoreSqlite.append_to_stream(name, notes(1))
      :ok
    end

    test "lists application streams by name, system streams on request" do
      assert names(EventstoreSqlite.list_stream_infos()) == ["a", "b", "c:100%_off", "d", "e"]
      assert names(EventstoreSqlite.list_stream_infos(system: true)) == ["$all", "a", "b", "c:100%_off", "d", "e"]
    end

    test "pages by name" do
      assert %{entries: [%{stream_id: "a"}, %{stream_id: "b"}], next: "b"} = EventstoreSqlite.list_stream_infos(limit: 2)
      assert %{next: "d"} = page = EventstoreSqlite.list_stream_infos(limit: 2, after: "b")
      assert names(page) == ["c:100%_off", "d"]
      assert %{entries: [%{stream_id: "e"}], next: nil} = EventstoreSqlite.list_stream_infos(limit: 2, after: "d")
    end

    test "a full last page has no next" do
      assert %{next: nil} = EventstoreSqlite.list_stream_infos(limit: 5)
    end

    test "a stream created between pages doesn't shift the next page" do
      first = EventstoreSqlite.list_stream_infos(limit: 2)
      :ok = EventstoreSqlite.append_to_stream("0", notes(1))
      assert names(EventstoreSqlite.list_stream_infos(limit: 2, after: first.next)) == ["c:100%_off", "d"]
    end

    test "searches anywhere in the name, ignoring case, with % and _ literal" do
      assert names(EventstoreSqlite.list_stream_infos(search: "100%_")) == ["c:100%_off"]
      assert names(EventstoreSqlite.list_stream_infos(search: "OFF")) == ["c:100%_off"]
      assert names(EventstoreSqlite.list_stream_infos(search: "0_o")) == []
      assert names(EventstoreSqlite.list_stream_infos(search: "")) == ["a", "b", "c:100%_off", "d", "e"]
    end

    test "searches and pages together" do
      for name <- ["x:1", "x:2", "x:3"], do: :ok = EventstoreSqlite.append_to_stream(name, notes(1))

      assert %{entries: [%{stream_id: "x:1"}, %{stream_id: "x:2"}], next: "x:2"} =
               EventstoreSqlite.list_stream_infos(search: "x:", limit: 2)

      assert names(EventstoreSqlite.list_stream_infos(search: "x:", limit: 2, after: "x:2")) == ["x:3"]
    end

    test "lists the newest streams first on request, paging by creation" do
      assert %{entries: [%{stream_id: "e"}, %{stream_id: "d"}], next: next} =
               EventstoreSqlite.list_stream_infos(order: :newest, limit: 2)

      :ok = EventstoreSqlite.append_to_stream("f", notes(1))

      assert names(EventstoreSqlite.list_stream_infos(order: :newest, limit: 2, after: next)) == ["c:100%_off", "a"]
      assert names(EventstoreSqlite.list_stream_infos(order: :newest, limit: 1)) == ["f"]
    end

    test "a stream archived and created again is the newest" do
      :ok = EventstoreSqlite.archive_stream("b")
      :ok = EventstoreSqlite.append_to_stream("b", notes(1))
      assert names(EventstoreSqlite.list_stream_infos(order: :newest, limit: 1)) == ["b"]
    end

    test "rejects an unknown order or a cursor it didn't hand out" do
      assert_raise ArgumentError, fn -> EventstoreSqlite.list_stream_infos(order: :size) end
      assert_raise ArgumentError, fn -> EventstoreSqlite.list_stream_infos(order: :newest, after: "b") end
    end

    test "rejects a limit that isn't a positive integer" do
      assert_raise ArgumentError, fn -> EventstoreSqlite.list_stream_infos(limit: 0) end
    end
  end
end
