defmodule EventstoreSqlite.Sync.StatusTest do
  use ExUnit.Case
  use EventstoreSqlite.DataCase
  use EventstoreSqlite.SyncCase

  import EventstoreSqlite.SyncEntries

  alias EventstoreSqlite.Sync.Export
  alias EventstoreSqlite.Sync.Import

  test "the log is empty with sync disabled" do
    assert %{enabled: false, head: 0, log: %{oldest: nil, entries: 0}, peers: peers} = Sync.status()
    assert peers == %{}
  end

  test "the log counts the entries retained for peers, until they are pruned" do
    :ok = Sync.enable("test-node")
    record!(%SystemEvents.PeerAdded{node_id: "peer", pinned_seq: 0})
    for i <- 1..3, do: :ok = EventstoreSqlite.append_to_stream("orders:#{i}", notes(1))

    assert %{head: 3, log: %{oldest: 1, entries: 3}} = Sync.status()

    query("INSERT INTO sync_acks (peer, seq) VALUES ('peer', 2)")
    EventstoreSqlite.RepoWrite.transact(fn repo -> {:ok, Export.prune(repo, State.load(repo))} end)

    assert %{head: 3, log: %{oldest: 3, entries: 1}, peers: %{"peer" => %{acked: 2}}} = Sync.status()
  end

  describe "a peer's last_applied_at" do
    setup do
      record!([
        %SystemEvents.SyncEnabled{node_id: "home", home: "home", sync_id: "group"},
        %SystemEvents.SnapshotClaimed{snapshot_id: "s", node_id: "test-node", snapshot_of: "home", cursor: 0}
      ])

      :ok
    end

    test "is nil until an entry is applied" do
      assert %{peers: %{"home" => %{last_applied_at: nil, lag: nil}}} = Sync.status()

      {:ok, _} = Import.import_entries("home", [], %{head: 4, diverged: false})
      assert %{peers: %{"home" => %{last_applied_at: nil, lag: 4}}} = Sync.status()
    end

    test "is when this node last applied one of its entries" do
      before = DateTime.truncate(DateTime.utc_now(), :second)
      {:ok, _} = Import.import_entries("home", [append_entry(1, "orders:1", 0, "a")], %{head: 2, diverged: false})

      assert %{peers: %{"home" => %{last_applied_at: %DateTime{} = applied_at, lag: 1}}} = Sync.status()
      assert DateTime.compare(applied_at, before) in [:gt, :eq]
    end

    test "doesn't move when only the peer's head does" do
      {:ok, _} = Import.import_entries("home", [append_entry(1, "orders:1", 0, "a")], %{head: 1, diverged: false})
      query("UPDATE sync_cursors SET applied_at = '2026-01-01T00:00:00Z'")

      {:ok, _} = Import.import_entries("home", [], %{head: 5, diverged: false})
      assert %{peers: %{"home" => %{last_applied_at: ~U[2026-01-01 00:00:00Z], lag: 4}}} = Sync.status()
    end
  end
end
