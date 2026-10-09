defmodule EventstoreSqlite.Sync.ClusterLifecycleTest do
  use ExUnit.Case

  import EventstoreSqlite.Cluster

  alias EventstoreSqlite.Cluster.Remote
  alias EventstoreSqlite.Ownership
  alias EventstoreSqlite.Sync
  alias EventstoreSqlite.Sync.Failpoint

  @moduletag :cluster
  @moduletag timeout: 180_000

  defp notes(texts), do: Remote.notes(texts)

  defp die_at(node, failpoint, trigger) do
    call(node, Failpoint, :set, [failpoint, :halt])
    ref = Process.monitor(node.peer)
    spawn(trigger)
    assert_receive {:DOWN, ^ref, :process, _, _}, 10_000
  end

  test "a node dying during a snapshot leaves no published file; the snapshot can be retried" do
    home = start!("main-node")
    :ok = call(home, Sync, :enable, ["main-node"])
    :ok = append(home, "orders:1", notes(["x"]))
    path = new_db_path()

    die_at(home, :snapshot_before_rename, fn -> call(home, Sync, :snapshot, [path, [peer: "secondary-node-1"]]) end)
    refute File.exists?(path)

    {:ok, home} = restart(home)
    assert call(home, Sync, :snapshot, [path, [peer: "secondary-node-1"]]) == {:error, {:exists, path <> ".tmp"}}
    assert status(home).peers["secondary-node-1"].acked == nil

    File.rm!(path <> ".tmp")
    {:ok, _} = call(home, Sync, :snapshot, [path, [peer: "secondary-node-1"]])
    second = start!("secondary-node-1", db: path)
    connect(home, second)
    converged(home, second)

    stop(home)
    stop(second)
  end

  test "a failed snapshot removes the peer it pinned" do
    home = start!("main-node")
    :ok = call(home, Sync, :enable, ["main-node"])
    call(home, Failpoint, :set, [:snapshot_after_vacuum, {:once, {:raise, "disk full"}}])
    path = new_db_path()

    assert {:error, {:snapshot_failed, "disk full"}} = call(home, Sync, :snapshot, [path, [peer: "secondary-node-1"]])
    refute File.exists?(path <> ".tmp")
    assert status(home).peers == %{}

    stop(home)
  end

  test "a node dying while claiming its snapshot claims it on the next boot" do
    home = start!("main-node")
    :ok = call(home, Sync, :enable, ["main-node"])
    :ok = append(home, "orders:1", notes(["x"]))
    path = new_db_path()
    {:ok, _} = call(home, Sync, :snapshot, [path, [peer: "secondary-node-1"]])

    {:ok, peer, _node} =
      :peer.start(%{
        name: :"esq_claim_#{System.unique_integer([:positive])}",
        connection: :standard_io,
        args: Enum.flat_map(:code.get_path(), &[~c"-pa", &1])
      })

    :peer.call(peer, Failpoint, :set, [:claim_before_commit, :halt])
    ref = Process.monitor(peer)

    env = [
      eventstore_sqlite:
        :eventstore_sqlite
        |> Application.get_all_env()
        |> Keyword.update!(EventstoreSqlite.RepoWrite, &Keyword.put(&1, :database, path))
        |> Keyword.update!(EventstoreSqlite.RepoRead, &Keyword.put(&1, :database, path))
        |> Keyword.put(:sync, node_id: "secondary-node-1")
    ]

    :peer.cast(peer, Remote, :boot, [env])
    assert_receive {:DOWN, ^ref, :process, _, _}, 30_000

    second = start!("secondary-node-1", db: path)
    assert status(second).node_id == "secondary-node-1"
    connect(home, second)
    converged(home, second)

    stop(home)
    stop(second)
  end

  test "the home node dying between an acknowledgement and pruning loses nothing" do
    {home, second} = pair()
    for i <- 1..10, do: :ok = append(home, "orders:#{i}", notes(["x"]))

    die_at(home, :between_ack_and_prune, fn -> :ok end)
    {:ok, home} = restart(home)
    connect(home, second)

    :ok = append(home, "orders:1", notes(["after"]))
    converged(home, second)

    stop(home)
    stop(second)
  end

  test "archives and reused names verify while lagging and after converging" do
    {home, second} = pair()
    generation = elem(call(home, Ownership, :assign, ["venue:*", "secondary-node-1"]), 1)
    wait_until(fn -> call(second, Ownership, :list, []) != [] end)

    :ok = append(second, "venue:1", notes(["a", "b"]))
    :ok = append(home, "orders:1", notes(["o"]))
    converged(home, second)

    disconnect(home, second)
    :ok = call(second, EventstoreSqlite, :archive_stream, ["venue:1"])
    :ok = append(second, "venue:1", notes(["reused"]))
    :ok = append(home, "orders:1", notes(["more"]))
    connect(home, second)

    lagging =
      wait_until(fn -> second |> call(Sync, :verify, ["main-node"]) |> then(&(&1 != {:error, :not_connected} and &1)) end)

    assert lagging == :ok or match?({:lag, _}, lagging), inspect(lagging, limit: :infinity)

    converged(home, second)
    assert texts(home, "venue:1") == ["reused"]
    assert :ok = call(home, Ownership, :reclaim, [generation])

    :ok = call(home, EventstoreSqlite, :archive_stream, ["venue:1"])
    :ok = append(home, "venue:1", notes(["home"]))
    converged(home, second)

    stop(home)
    stop(second)
  end

  test "a forked stream is reported, not hidden" do
    {home, second} = pair()
    :ok = append(home, "orders:1", notes(["a"]))
    converged(home, second)

    call(second, Ecto.Adapters.SQL, :query!, [
      EventstoreSqlite.RepoWrite,
      "UPDATE sync_state SET value = ?1",
      [
        {:blob,
         :erlang.term_to_binary(%{call(second, Sync, :state, []) | home: "secondary-node-1", node_id: "secondary-node-1"})}
      ]
    ])

    :ok = append(second, "orders:1", notes(["fork"]))
    :ok = append(home, "orders:1", notes(["b"]))
    Process.sleep(300)

    assert {:error, [{"orders:1", _}]} = call(home, Sync, :verify, ["secondary-node-1"])

    stop(home)
    stop(second)
  end

  test "disable, re-enable and provision a new peer" do
    {home, second} = pair()
    :ok = append(home, "orders:1", notes(["first group"]))
    converged(home, second)

    assert call(home, Sync, :remove_peer, ["secondary-node-1"]) == :ok
    stop(second)
    assert :ok = call(home, Sync, :disable, [])
    :ok = append(home, "orders:1", notes(["unsynced"]))
    assert :ok = call(home, Sync, :enable, ["main-node"])

    path = new_db_path()
    {:ok, _} = call(home, Sync, :snapshot, [path, [peer: "secondary-node-2"]])
    second = start!("secondary-node-2", db: path)
    connect(home, second)
    :ok = append(home, "orders:1", notes(["second group"]))
    converged(home, second)

    for node <- [home, second] do
      before = call(node, Sync, :state, [])
      :ok = call(node, Sync, :rebuild_state, [])
      assert call(node, Sync, :state, []) == before
    end

    assert texts(second, "orders:1") == ["first group", "unsynced", "second group"]

    stop(home)
    stop(second)
  end
end
