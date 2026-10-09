defmodule EventstoreSqlite.Sync.ClusterFailureTest do
  use ExUnit.Case

  import EventstoreSqlite.Cluster

  alias EventstoreSqlite.Cluster.Remote
  alias EventstoreSqlite.Sync
  alias EventstoreSqlite.Sync.Failpoint

  @moduletag :cluster
  @moduletag timeout: 180_000

  defp notes(texts), do: Remote.notes(texts)

  defp sync_log_count(node) do
    [[count]] =
      call(node, Ecto.Adapters.SQL, :query!, [EventstoreSqlite.RepoRead, "SELECT count(*) FROM sync_log", []]).rows

    count
  end

  test "a partition only delays replication" do
    {home, second} = pair()
    disconnect(home, second)

    for i <- 1..50, do: :ok = append(home, "orders:#{rem(i, 5)}", notes(["p#{i}"]))
    Process.sleep(300)
    assert status(second).peers["main-node"].state == :disconnected
    assert read(second, "orders:1") == []

    connect(home, second)
    converged(home, second)

    stop(home)
    stop(second)
  end

  test "the second node dying at every import step converges without duplicates" do
    {home, second} = pair()

    triggers = [
      import_after_commit: fn -> :ok = append(home, "s", notes(["next"])) end,
      archive_before_commit: fn -> :ok = call(home, EventstoreSqlite, :archive_stream, ["gone:1"]) end,
      archive_after_commit: fn -> :ok = call(home, EventstoreSqlite, :archive_stream, ["gone:2"]) end
    ]

    :ok = append(home, "gone:1", notes(["x"]))
    :ok = append(home, "gone:2", notes(["y"]))

    second =
      Enum.reduce(triggers, second, fn {failpoint, trigger}, second ->
        :ok = append(home, "s", notes(["before #{failpoint}"]))
        caught_up(second, home)

        call(second, Failpoint, :set, [failpoint, :halt])
        ref = Process.monitor(second.peer)
        trigger.()
        assert_receive {:DOWN, ^ref, :process, _, _}, 10_000

        {:ok, second} = restart(second)
        connect(home, second)
        converged(home, second)
        second
      end)

    assert texts(second, "s") == [
             "before import_after_commit",
             "next",
             "before archive_before_commit",
             "before archive_after_commit"
           ]

    assert read(second, "gone:1") == []
    assert read(second, "gone:2") == []

    stop(home)
    stop(second)
  end

  test "a replicator killed before notifying subscribers doesn't lose their events" do
    {home, second} = pair()
    collector = call(second, Remote, :collect, ["orders:1"])
    call(second, Failpoint, :set, [:import_after_commit, {:once, {:exit, :kill}}])

    :ok = append(home, "orders:1", notes(["a"]))

    received = wait_until(fn -> match?([_], call(second, Remote, :received, [collector])) end)
    assert received
    assert [{0, _, %{text: "a"}}] = call(second, Remote, :received, [collector])

    stop(home)
    stop(second)
  end

  test "a snapshot taken while the home node writes converges" do
    home = start!("main-node")
    :ok = call(home, Sync, :enable, ["main-node"])

    writer =
      Task.async(fn ->
        for i <- 1..400, do: :ok = append(home, "load:#{rem(i, 7)}", notes(["w#{i}"]))
      end)

    Process.sleep(50)
    path = new_db_path()
    {:ok, _} = call(home, Sync, :snapshot, [path, [peer: "secondary-node-1"]])
    second = start!("secondary-node-1", db: path)
    connect(home, second)
    Task.await(writer, 60_000)

    converged(home, second)

    stop(home)
    stop(second)
  end

  test "the home node prunes what the second node pulled; removing the peer empties the log" do
    {home, second} = pair()
    for i <- 1..30, do: :ok = append(home, "orders:#{i}", notes(["x"]))

    caught_up(second, home)
    wait_until(fn -> sync_log_count(home) == 0 end)

    stop(second)
    for i <- 1..5, do: :ok = append(home, "orders:#{i}", notes(["y"]))
    assert sync_log_count(home) == 5

    assert call(home, Sync, :remove_peer, ["secondary-node-1"]) == {:error, :not_caught_up}
    assert call(home, Sync, :remove_peer, ["secondary-node-1", [discard_unpulled: true]]) == :ok
    assert sync_log_count(home) == 0
    assert call(home, Sync, :disable, []) == :ok

    stop(home)
  end

  test "a peer behind the pruned range halts" do
    {home, second} = pair()
    stale_copy = new_db_path()
    File.cp!(second.db, stale_copy)

    for i <- 1..10, do: :ok = append(home, "orders:#{i}", notes(["x"]))
    caught_up(second, home)
    wait_until(fn -> sync_log_count(home) == 0 end)
    stop(second)

    {:ok, stale} = start("secondary-node-1", db: stale_copy)
    connect(home, stale)

    assert wait_until(fn -> status(stale).peers["main-node"].halted end) == :pruned

    stop(home)
    stop(stale)
  end
end
