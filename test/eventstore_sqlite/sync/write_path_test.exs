defmodule EventstoreSqlite.Sync.WritePathTest do
  use ExUnit.Case
  use EventstoreSqlite.DataCase
  use EventstoreSqlite.SyncCase

  alias EventstoreSqlite.Sync.Boot

  describe "with sync disabled" do
    test "appends and archives write no log and behave as before" do
      :ok = EventstoreSqlite.append_to_stream("a", notes(2))
      :ok = EventstoreSqlite.archive_stream("a")

      assert log_rows() == []
      assert query("SELECT count(*) FROM sync_state") == [[0]]
      refute Sync.state().enabled
    end

    test "the reserved names can't be appended to" do
      for stream <- ["$sync", "$ownership"] do
        assert EventstoreSqlite.append_to_stream(stream, [note("x")]) == {:error, :system_stream}
        assert EventstoreSqlite.archive_stream(stream) == {:error, :system_stream}
      end
    end
  end

  describe "enable/1" do
    test "requires the configured node id" do
      assert Sync.enable("other") == {:error, {:node_id_not_configured, "test-node"}}
      refute Sync.state().enabled
    end

    test "makes this node home and records SyncEnabled" do
      assert Sync.enable("test-node") == :ok
      state = Sync.state()
      assert %State{enabled: true, node_id: "test-node", home: "test-node"} = state
      assert is_binary(state.sync_id)

      assert [%SystemEvents.SyncEnabled{node_id: "test-node"}] =
               Enum.map(EventstoreSqlite.read_stream_forward("$sync"), & &1.data)

      assert Sync.enable("test-node") == {:error, :already_enabled}
    end

    test "the sync streams don't appear in $all" do
      :ok = Sync.enable("test-node")
      :ok = EventstoreSqlite.append_to_stream("a", [note("x")])

      assert Enum.map(EventstoreSqlite.read_stream_forward("$all"), & &1.original_stream_id) == ["a"]
    end
  end

  describe "the log while sync is enabled" do
    setup do
      :ok = Sync.enable("test-node")
    end

    test "an append writes one entry with its event ids in order" do
      :ok = EventstoreSqlite.append_to_stream("a", notes(3))
      :ok = EventstoreSqlite.append_to_stream("a", notes(2))
      :ok = EventstoreSqlite.append_to_stream("b", notes(1))

      assert log_rows() == [[1, "append", "a", 0, 0], [2, "append", "a", 3, 0], [3, "append", "b", 0, 0]]

      ids = Enum.map(EventstoreSqlite.read_stream_forward("a"), & &1.id)
      assert log_event_ids(1) ++ log_event_ids(2) == ids
    end

    test "an archive writes an entry with the archived event count" do
      :ok = EventstoreSqlite.append_to_stream("a", notes(3))
      :ok = EventstoreSqlite.archive_stream("a")

      assert log_rows() == [[1, "append", "a", 0, 0], [2, "archive", "a", 3, 0]]
    end

    test "a rejected append leaves no gap in the seqs" do
      :ok = EventstoreSqlite.append_to_stream("a", notes(1))
      assert {:error, :wrong_expected_version} = EventstoreSqlite.append_to_stream("a", notes(1), :no_stream)
      :ok = EventstoreSqlite.append_to_stream("a", notes(1))

      assert Enum.map(log_rows(), &hd/1) == [1, 2]
    end

    test "a failing batch leaves no entry" do
      id = Ecto.UUID.generate()
      :ok = EventstoreSqlite.append_to_stream("a", [%EventstoreSqlite.NewEvent{id: id, data: note("x")}])

      assert_raise Exqlite.Error, fn ->
        EventstoreSqlite.append_to_stream("b", [note("y"), %EventstoreSqlite.NewEvent{id: id, data: note("z")}])
      end

      assert Enum.map(log_rows(), &hd/1) == [1]
    end
  end

  describe "ownership on the write path" do
    setup do
      :ok = Sync.enable("test-node")

      record!([
        %SystemEvents.PeerAdded{node_id: "other", pinned_seq: 0},
        %SystemEvents.OwnershipAssigned{selector: "venue:*", to: "other", generation: 7}
      ])

      :ok
    end

    test "streams assigned to another node are refused, others are written under generation 0" do
      assert EventstoreSqlite.append_to_stream("venue:1", [note("x")]) == {:error, :not_owner}
      assert EventstoreSqlite.archive_stream("venue:1") == {:error, :not_owner}
      assert EventstoreSqlite.read_stream_forward("venue:1") == []

      :ok = EventstoreSqlite.append_to_stream("orders:1", [note("x")])
      assert log_rows() == [[1, "append", "orders:1", 0, 0]]
    end

    test "a stream assigned to this node is written under its generation" do
      record!(%SystemEvents.OwnershipAssigned{selector: "mine", to: "test-node", generation: 9})

      :ok = EventstoreSqlite.append_to_stream("mine", [note("x")])
      assert log_rows() == [[1, "append", "mine", 0, 9]]
    end

    test "a node that isn't home owns nothing without an assignment" do
      record!([
        %SystemEvents.SyncEnabled{node_id: "home", home: "home", sync_id: "group"},
        %SystemEvents.SnapshotClaimed{snapshot_id: "s", node_id: "test-node", snapshot_of: "home", cursor: 0}
      ])

      assert EventstoreSqlite.append_to_stream("orders:1", [note("x")]) == {:error, :not_owner}
    end

    test "a diverged node refuses every write, even of streams it owned" do
      record!([
        %SystemEvents.OwnershipAssigned{selector: "mine", to: "test-node", generation: 9},
        %SystemEvents.NodeDiverged{node_id: "test-node", revoked_by: "home", revoke_seq: 3}
      ])

      assert EventstoreSqlite.append_to_stream("mine", [note("x")]) == {:error, :diverged}
      assert EventstoreSqlite.append_to_stream("orders:1", [note("x")]) == {:error, :diverged}
      assert Sync.disable() == {:error, :diverged}
    end
  end

  describe "disable/0" do
    test "requires no peers and no assignments, then empties the log" do
      :ok = Sync.enable("test-node")
      :ok = EventstoreSqlite.append_to_stream("a", notes(2))

      record!(%SystemEvents.PeerAdded{node_id: "other", pinned_seq: 0})
      assert Sync.disable() == {:error, :peers_remaining}

      record!(%SystemEvents.PeerRemoved{node_id: "other"})
      assert Sync.disable() == :ok

      assert log_rows() == []
      assert query("SELECT count(*) FROM sync_log_events") == [[0]]
      refute Sync.state().enabled

      :ok = EventstoreSqlite.append_to_stream("a", notes(1))
      assert log_rows() == []
    end

    test "a re-enable starts a new group and keeps the seq counter" do
      :ok = Sync.enable("test-node")
      :ok = EventstoreSqlite.append_to_stream("a", notes(1))
      %State{sync_id: first_group} = Sync.state()
      :ok = Sync.disable()

      :ok = Sync.enable("test-node")
      :ok = EventstoreSqlite.append_to_stream("a", notes(1))

      assert Sync.state().sync_id != first_group
      assert Enum.map(log_rows(), &hd/1) == [2]
    end
  end

  test "rebuild_state/0 replays to the same state" do
    :ok = Sync.enable("test-node")

    record!([
      %SystemEvents.PeerAdded{node_id: "other", pinned_seq: 0},
      %SystemEvents.OwnershipAssigned{selector: "venue:*", to: "other", generation: 1},
      %SystemEvents.OwnershipAssigned{selector: "shop:*", to: "other", generation: 2},
      %SystemEvents.OwnershipReleased{generation: 1, from: "other", release_seq: 4},
      %SystemEvents.OwnershipRevoked{generation: 2, selector: "shop:*", from: "other", cutoff: 4},
      %SystemEvents.NodeRetired{node_id: "other", revoke_seq: 3},
      %SystemEvents.SyncHalted{peer: "other", reason: :gap}
    ])

    incremental = Sync.state()
    query("DELETE FROM sync_state")
    :ok = Sync.rebuild_state()

    assert Sync.state() == incremental
  end

  describe "Boot.check/2" do
    alias EventstoreSqlite.RepoWrite

    test "a store without sync starts under any configuration" do
      assert Boot.check(RepoWrite, nil) == :ok
      assert Boot.check(RepoWrite, "anything") == :ok
    end

    test "an enabled store only starts under its own node id" do
      :ok = Sync.enable("test-node")

      assert Boot.check(RepoWrite, "test-node") == :ok
      assert {:error, message} = Boot.check(RepoWrite, "other")
      assert message =~ ~s(belongs to sync node "test-node")
      assert {:error, message} = Boot.check(RepoWrite, nil)
      assert message =~ "no node id is configured"
    end

    test "a snapshot can only be claimed by the node it was made for" do
      :ok = Sync.enable("test-node")

      snapshot = %SystemEvents.SnapshotCreated{
        snapshot_id: "s",
        for_node: "node-1",
        snapshot_of: "test-node",
        head_seq: 0
      }

      record!(snapshot)

      assert Boot.check(RepoWrite, "node-1") == {:claim, snapshot}
      assert {:error, message} = Boot.check(RepoWrite, "test-node")
      assert message =~ ~s(snapshot made for node "node-1")
    end
  end

  test "the migration refuses a store that already has a stream with a reserved name" do
    query("INSERT INTO streams (stream_id, stream_version, inserted_at) VALUES ('$sync', 0, '2026-01-01T00:00:00Z')")

    assert_raise RuntimeError, ~r/"\$sync" already exists/, fn ->
      EventstoreSqlite.Migration.check_stream_name_free!(EventstoreSqlite.RepoWrite, "$sync")
    end

    :ok = EventstoreSqlite.Migration.check_stream_name_free!(EventstoreSqlite.RepoWrite, "$ownership")
  end
end
