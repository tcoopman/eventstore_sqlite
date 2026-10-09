defmodule EventstoreSqlite.Sync.ExportTest do
  use ExUnit.Case
  use EventstoreSqlite.DataCase
  use EventstoreSqlite.SyncCase

  alias EventstoreSqlite.Sync.Export
  alias EventstoreSqlite.Sync.Import

  setup do
    :ok = Sync.enable("test-node")
    record!(%SystemEvents.PeerAdded{node_id: "peer", pinned_seq: 0})
    :ok
  end

  defp request(after_seq, overrides \\ []) do
    Map.merge(
      %{
        protocol: Export.protocol(),
        sync_id: Sync.state().sync_id,
        from: "peer",
        expect: "test-node",
        after_seq: after_seq,
        max_entries: 500,
        max_bytes: 8_000_000
      },
      Map.new(overrides)
    )
  end

  defp seqs({:ok, %{entries: entries}}), do: Enum.map(entries, & &1.seq)

  test "returns the entries after the requested seq, with the head and this node's state" do
    :ok = EventstoreSqlite.append_to_stream("a", notes(2))
    :ok = EventstoreSqlite.append_to_stream("b", notes(1))
    :ok = EventstoreSqlite.archive_stream("a")

    assert {:ok, response} = Sync.export(request(1))
    assert %{head: 3, diverged: false, node_id: "test-node"} = response

    assert [
             %{seq: 2, kind: :append, stream_id: "b", stream_version: 0, generation: 0, events: [%{data: data}]},
             %{seq: 3, kind: :archive, stream_id: "a", stream_version: 2, events: []}
           ] = response.entries

    assert :erlang.binary_to_term(data) == note("n1")
  end

  test "an entry of a stream archived since is still complete" do
    :ok = EventstoreSqlite.append_to_stream("a", notes(2))
    :ok = EventstoreSqlite.archive_stream("a")

    assert {:ok, %{entries: [%{events: events} | _]}} = Sync.export(request(0))
    assert Enum.map(events, &:erlang.binary_to_term(&1.data)) == notes(2)
  end

  test "idle, ahead of origin, and pruned" do
    :ok = EventstoreSqlite.append_to_stream("a", notes(1))
    :ok = EventstoreSqlite.append_to_stream("a", notes(1))

    assert Sync.export(request(3)) == {:error, :ahead_of_origin}

    assert seqs(Sync.export(request(1))) == [2]
    assert Enum.map(log_rows(), &hd/1) == [2]
    assert Sync.export(request(0)) == {:error, :pruned}

    assert {:ok, %{entries: [], head: 2}} = Sync.export(request(2))
    assert log_rows() == []
    assert Sync.export(request(1)) == {:error, :pruned}
  end

  test "requests from another group, for another node, from a stranger or another protocol are refused" do
    assert Sync.export(request(0, sync_id: "other")) == {:error, :sync_id_mismatch}
    assert Sync.export(request(0, expect: "someone")) == {:error, {:wrong_node, "test-node"}}
    assert Sync.export(request(0, from: "stranger")) == {:error, :unknown_peer}
    assert Sync.export(request(0, protocol: 99)) == {:error, {:protocol, 99, Export.protocol()}}
  end

  test "limits: entry count and bytes, but always at least one whole entry" do
    for _ <- 1..5, do: :ok = EventstoreSqlite.append_to_stream("a", notes(3))

    assert seqs(Sync.export(request(0, max_entries: 2))) == [1, 2]
    assert seqs(Sync.export(request(0, max_bytes: 1))) == [1]
  end

  test "a peer that never acknowledged holds the log at its pin" do
    record!(%SystemEvents.PeerAdded{node_id: "late", pinned_seq: 1})
    for _ <- 1..3, do: :ok = EventstoreSqlite.append_to_stream("a", notes(1))

    {:ok, _} = Sync.export(request(3))
    assert Enum.map(log_rows(), &hd/1) == [2, 3]
  end

  test "a round trip keeps every event byte for byte" do
    :ok =
      EventstoreSqlite.append_to_stream("a", [%EventstoreSqlite.NewEvent{data: note("x"), metadata: %{c: 1}}, note("y")])

    {:ok, %{entries: entries, head: head}} = Sync.export(request(0))

    rows = fn ->
      query(
        "SELECT id, type, data, metadata, inserted_at, typeof(metadata) FROM events WHERE type LIKE '%Test.Note' ORDER BY id"
      )
    end

    exported = rows.()
    EventstoreSqlite.DataCase.reset!()

    record!([
      %SystemEvents.SyncEnabled{node_id: "home", home: "home", sync_id: "g"},
      %SystemEvents.SnapshotClaimed{snapshot_id: "s", node_id: "test-node", snapshot_of: "home", cursor: 0}
    ])

    {:ok, _} = Import.import_entries("home", entries, %{head: head, diverged: false})
    assert rows.() == exported
  end
end
