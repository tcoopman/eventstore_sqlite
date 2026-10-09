defmodule EventstoreSqlite.ChangesTest do
  use ExUnit.Case
  use EventstoreSqlite.DataCase
  use EventstoreSqlite.SyncCase

  import EventstoreSqlite.SyncEntries

  alias EventstoreSqlite.Sync.Import

  test "an append is reported as a change to the streams" do
    :ok = EventstoreSqlite.subscribe_to_changes(self())
    :ok = EventstoreSqlite.append_to_stream("orders:1", notes(1))
    assert_receive {:eventstore_sqlite, :changed, [:streams]}
  end

  test "an archive is reported" do
    :ok = EventstoreSqlite.append_to_stream("orders:1", notes(1))
    :ok = EventstoreSqlite.subscribe_to_changes(self())
    :ok = EventstoreSqlite.archive_stream("orders:1")
    assert_receive {:eventstore_sqlite, :changed, [:streams]}
  end

  test "with sync enabled an append also changes the sync status" do
    :ok = Sync.enable("test-node")
    :ok = EventstoreSqlite.subscribe_to_changes(self())
    :ok = EventstoreSqlite.append_to_stream("orders:1", notes(1))
    assert_receive {:eventstore_sqlite, :changed, [:streams, :sync]}
  end

  test "a sync state change is reported, since it can change owners" do
    :ok = EventstoreSqlite.subscribe_to_changes(self())
    :ok = Sync.enable("test-node")
    assert_receive {:eventstore_sqlite, :changed, [:streams, :sync]}
  end

  test "an import is reported" do
    record!([
      %SystemEvents.SyncEnabled{node_id: "home", home: "home", sync_id: "group"},
      %SystemEvents.SnapshotClaimed{snapshot_id: "s", node_id: "test-node", snapshot_of: "home", cursor: 0}
    ])

    :ok = EventstoreSqlite.subscribe_to_changes(self())
    {:ok, _} = Import.import_entries("home", [append_entry(1, "orders:1", 0, "a")], %{head: 1, diverged: false})
    assert_receive {:eventstore_sqlite, :changed, [:streams, :sync]}
  end

  test "changes within a second are coalesced into one more message" do
    :ok = EventstoreSqlite.subscribe_to_changes(self())

    :ok = EventstoreSqlite.append_to_stream("orders:1", notes(1))
    assert_receive {:eventstore_sqlite, :changed, [:streams]}

    for _ <- 1..5, do: :ok = EventstoreSqlite.append_to_stream("orders:1", notes(1))
    refute_receive {:eventstore_sqlite, :changed, _}, 500
    assert_receive {:eventstore_sqlite, :changed, [:streams]}, 1_000
    refute_receive {:eventstore_sqlite, :changed, _}, 1_200
  end

  test "subscribing twice delivers once" do
    :ok = EventstoreSqlite.subscribe_to_changes(self())
    :ok = EventstoreSqlite.subscribe_to_changes(self())
    :ok = EventstoreSqlite.append_to_stream("orders:1", notes(1))
    assert_receive {:eventstore_sqlite, :changed, _}
    refute_receive {:eventstore_sqlite, :changed, _}, 100
  end

  test "a subscriber that exits is dropped" do
    subscriber = spawn(fn -> receive(do: (:stop -> :ok)) end)
    :ok = EventstoreSqlite.subscribe_to_changes(subscriber)
    ref = Process.monitor(subscriber)
    send(subscriber, :stop)
    assert_receive {:DOWN, ^ref, :process, _, _}

    :sys.get_state(EventstoreSqlite.Changes)
    refute Map.has_key?(:sys.get_state(EventstoreSqlite.Changes).subscribers, subscriber)
  end
end
