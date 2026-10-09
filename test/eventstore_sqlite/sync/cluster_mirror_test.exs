defmodule EventstoreSqlite.Sync.ClusterMirrorTest do
  use ExUnit.Case

  import EventstoreSqlite.Cluster

  alias EventstoreSqlite.Cluster
  alias EventstoreSqlite.Cluster.Remote
  alias EventstoreSqlite.Sync

  @moduletag :cluster
  @moduletag timeout: 120_000

  defp notes(texts), do: Remote.notes(texts)

  test "the second node mirrors the home node: history from the snapshot, then live appends" do
    {home, second} =
      pair("main-node", "secondary-node-1",
        before_snapshot: fn home ->
          for i <- 1..20, do: :ok = append(home, "orders:#{rem(i, 4)}", notes(["before-#{i}"]))
        end
      )

    for i <- 1..200, do: :ok = append(home, "orders:#{rem(i, 10)}", notes(["e#{i}a", "e#{i}b"]))

    converged(home, second)
    assert texts(second, "orders:3") == texts(home, "orders:3")
    assert length(read(second, "$all")) == length(read(home, "$all"))

    stop(home)
    stop(second)
  end

  test "the second node owns nothing without an assignment" do
    {home, second} = pair()

    assert append(second, "orders:1", notes("x")) == {:error, :not_owner}
    assert append(second, "anything", notes("x")) == {:error, :not_owner}
    assert call(second, EventstoreSqlite, :archive_stream, ["orders:1"]) == {:error, :not_owner}

    stop(home)
    stop(second)
  end

  test "a large batch becomes visible on the second node all at once" do
    {home, second} = pair()
    caught_up(second, home)

    batch = notes(Enum.map(1..5_000, &"b#{&1}"))
    watcher = Task.async(fn -> watch_versions(second, "big", []) end)
    :ok = append(home, "big", batch)

    versions = Task.await(watcher, 30_000)
    assert Enum.uniq(versions) -- [0, 5_000] == []
    assert List.last(versions) == 5_000

    stop(home)
    stop(second)
  end

  defp watch_versions(node, stream, seen) do
    version =
      call(node, Ecto.Adapters.SQL, :query!, [
        EventstoreSqlite.RepoRead,
        "SELECT stream_version FROM streams WHERE stream_id = ?1",
        [stream]
      ]).rows

    version =
      case version do
        [[v]] -> v
        [] -> 0
      end

    if version == 5_000, do: Enum.reverse([version | seen]), else: watch_versions(node, stream, [version | seen])
  end

  test "subscribers on the second node receive the home node's events" do
    {home, second} = pair()
    collector = call(second, Remote, :collect, ["orders:1"])

    :ok = append(home, "orders:1", notes(["a", "b"]))
    :ok = append(home, "orders:1", notes(["c"]))

    received =
      wait_until(fn ->
        length(call(second, Remote, :received, [collector])) == 3 and call(second, Remote, :received, [collector])
      end)

    assert Enum.map(received, fn {version, _id, data} -> {version, data.text} end) == [{0, "a"}, {1, "b"}, {2, "c"}]

    stop(home)
    stop(second)
  end

  test "a snapshot can be claimed once, only by the node it was made for" do
    home = start!("main-node")
    :ok = call(home, Sync, :enable, ["main-node"])
    path = new_db_path()
    {:ok, _} = call(home, Sync, :snapshot, [path, [peer: "secondary-node-1"]])

    assert {:error, _} = Cluster.start("secondary-node-2", db: path)

    copy = new_db_path()
    File.cp!(path, copy)
    second = start!("secondary-node-1", db: path)
    stop(second)

    assert {:error, _} = Cluster.start("secondary-node-1", db: copy, configured_node_id: "secondary-node-9")
    assert {:ok, again} = Cluster.restart(second)
    assert status(again).node_id == "secondary-node-1"

    :ok = call(again, Sync, :rebuild_state, [])
    assert status(again).node_id == "secondary-node-1"

    assert call(home, Sync, :snapshot, [new_db_path(), [peer: "secondary-node-2"]]) ==
             {:error, {:peer_exists, "secondary-node-1"}}

    stop(home)
    stop(again)
  end
end
