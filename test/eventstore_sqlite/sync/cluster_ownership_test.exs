defmodule EventstoreSqlite.Sync.ClusterOwnershipTest do
  use ExUnit.Case

  import EventstoreSqlite.Cluster

  alias EventstoreSqlite.Cluster.Remote
  alias EventstoreSqlite.Ownership
  alias EventstoreSqlite.Sync
  alias EventstoreSqlite.Sync.Failpoint

  @moduletag :cluster
  @moduletag timeout: 180_000

  defp notes(texts), do: Remote.notes(texts)

  defp assign!(home, second, selector) do
    {:ok, generation} = call(home, Ownership, :assign, [selector, second.node_id])
    wait_until(fn -> Enum.any?(call(second, Ownership, :list, []), &(&1.generation == generation)) end)
    generation
  end

  defp ids(node, stream), do: node |> read(stream) |> Enum.map(& &1.id)

  test "an assignment moves writing to the second node, and replication flows both ways" do
    {home, second} = pair()
    :ok = append(home, "venue:1", notes(["home-before"]))

    generation = assign!(home, second, "venue:*")

    assert append(home, "venue:1", notes(["x"])) == {:error, :not_owner}
    assert append(home, "venue:2", notes(["x"])) == {:error, :not_owner}
    assert :ok = append(second, "venue:1", notes(["second"]))
    assert :ok = append(home, "orders:1", notes(["home"]))
    assert append(second, "orders:1", notes(["x"])) == {:error, :not_owner}

    converged(home, second)
    assert texts(home, "venue:1") == ["home-before", "second"]
    assert call(home, Ownership, :owner, ["venue:9"]) == {"secondary-node-1", generation}
    assert status(home).peers["secondary-node-1"].owns == [generation]

    stop(home)
    stop(second)
  end

  test "assignments can't overlap, and need a known peer" do
    {home, second} = pair()
    _generation = assign!(home, second, "venue:*")

    assert call(home, Ownership, :assign, ["venue:vip", "secondary-node-1"]) == {:error, :overlap}
    assert call(home, Ownership, :assign, ["venue:vip:*", "secondary-node-1"]) == {:error, :overlap}
    assert call(home, Ownership, :assign, ["ven*", "secondary-node-1"]) == {:error, :overlap}
    assert call(home, Ownership, :assign, ["orders:*", "stranger"]) == {:error, :unknown_peer}
    assert call(home, Ownership, :assign, ["orders:*", "main-node"]) == {:error, :home}
    assert call(second, Ownership, :assign, ["orders:*", "secondary-node-1"]) == {:error, :not_home}

    stop(home)
    stop(second)
  end

  test "a planned handover under load loses no acknowledged write and never accepts a version twice" do
    {home, second} = pair()
    generation = assign!(home, second, "venue:*")
    streams = Enum.map(1..20, &"venue:#{&1}")

    writers = call(second, Remote, :start_writers, [streams])
    Process.sleep(500)

    assert call(home, Ownership, :reclaim, [generation]) == :ok
    {acked, reasons} = call(second, Remote, :stop_writers, [writers])

    assert map_size(reasons) == 20
    assert Enum.all?(Map.values(reasons), &(&1 in [:not_owner, :stopped]))
    assert length(acked) > 20

    for stream <- streams do
      acked_ids = for {^stream, _version, id} <- acked, do: id
      assert ids(home, stream) == acked_ids
    end

    assert :ok = append(home, "venue:1", notes(["home-again"]))
    assert append(second, "venue:1", notes(["x"])) == {:error, :not_owner}
    converged(home, second)
    assert call(home, Ownership, :list, []) == []

    stop(home)
    stop(second)
  end

  test "a lost release reply: the retry succeeds and releases nothing twice" do
    {home, second} = pair()
    generation = assign!(home, second, "venue:*")
    call(second, Failpoint, :set, [:release_after_commit, {:once, {:raise, "reply lost"}}])

    assert call(home, Ownership, :reclaim, [generation]) == {:error, :unreachable}
    assert call(home, Ownership, :reclaim, [generation]) == :ok

    released =
      second
      |> read("$ownership")
      |> Enum.count(&match?(%EventstoreSqlite.SystemEvents.OwnershipReleased{}, &1.data))

    assert released == 1

    stop(home)
    stop(second)
  end

  test "a timed-out reclaim retried after a reassignment leaves the new assignment alone" do
    {home, second} = pair()
    first = assign!(home, second, "venue:*")

    assert call(home, Ownership, :reclaim, [first, [timeout: 0]]) == {:error, :timeout}
    wait_until(fn -> call(home, Ownership, :list, []) == [] end)

    second_generation = assign!(home, second, "venue:*")
    assert call(home, Ownership, :reclaim, [first]) == :ok
    assert [%{generation: ^second_generation}] = call(home, Ownership, :list, [])
    assert :ok = append(second, "venue:1", notes(["still mine"]))

    stop(home)
    stop(second)
  end

  test "writes racing an assignment are either before it on both nodes, or refused" do
    {home, second} = pair()
    writers = call(home, Remote, :start_writers, [["venue:1", "venue:2", "venue:3"]])
    Process.sleep(200)

    {:ok, generation} = call(home, Ownership, :assign, ["venue:*", "secondary-node-1"])
    {acked, reasons} = call(home, Remote, :stop_writers, [writers])
    assert Map.values(reasons) == [:not_owner, :not_owner, :not_owner]

    wait_until(fn -> Enum.any?(call(second, Ownership, :list, []), &(&1.generation == generation)) end)
    :ok = append(second, "venue:1", [%EventstoreSqlite.NewEvent{id: first = Ecto.UUID.generate(), data: hd(notes("s"))}])

    home_ids = for {"venue:1", _, id} <- acked, do: id
    assert ids(second, "venue:1") == home_ids ++ [first]
    converged(home, second)

    stop(home)
    stop(second)
  end

  test "a forced reclaim of a writing, partitioned node quarantines exactly its unpulled writes" do
    {home, second} = pair()
    generation = assign!(home, second, "venue:*")
    :ok = append(second, "venue:1", notes(["pulled"]))
    caught_up(home, second)

    disconnect(home, second)
    :ok = append(second, "venue:1", notes(["late-1"]))
    :ok = append(second, "venue:1", notes(["late-2"]))
    :ok = call(second, EventstoreSqlite, :archive_stream, ["venue:1"])

    assert call(home, Ownership, :revoke_node, ["secondary-node-1"]) == {:ok, [generation]}
    assert status(home).peers["secondary-node-1"].state == :retired
    assert :ok = append(home, "venue:1", notes(["home-takes-over"]))
    assert call(home, Sync, :remove_peer, ["secondary-node-1"]) == {:error, :not_drained}

    connect(home, second)
    wait_until(fn -> status(home).peers["secondary-node-1"].state == :drained end)

    assert texts(home, "venue:1") == ["pulled", "home-takes-over"]
    quarantined = call(home, Sync, :quarantine, [])
    assert Enum.map(quarantined, & &1.entry.kind) == [:append, :append, :archive]

    assert status(second).diverged == %{revoked_by: "main-node", revoke_seq: status(second).diverged.revoke_seq}
    assert append(second, "venue:2", notes(["x"])) == {:error, :diverged}
    assert append(second, "orders:1", notes(["x"])) == {:error, :diverged}
    assert call(second, Sync, :disable, []) == {:error, :diverged}
    assert call(second, Sync, :remove_peer, ["main-node"]) == {:error, :diverged}
    assert call(second, Sync, :resume, ["main-node"]) == {:error, :diverged}

    assert call(home, Sync, :remove_peer, ["secondary-node-1"]) == :ok
    assert call(home, Sync, :disable, []) == :ok

    stop(home)
    stop(second)
  end

  test "a release still in flight doesn't save a revoked node from diverging" do
    {home, second} = pair()
    generation = assign!(home, second, "venue:*")
    disconnect(home, second)

    assert {:ok, _} = call(second, Ownership, :release, [generation])
    assert call(second, Ownership, :list, []) == []
    assert {:ok, [^generation]} = call(home, Ownership, :revoke_node, ["secondary-node-1"])

    connect(home, second)
    wait_until(fn -> status(second).diverged end)
    wait_until(fn -> status(home).peers["secondary-node-1"].state == :drained end)

    assert Enum.any?(read(home, "$ownership"), &match?(%EventstoreSqlite.SystemEvents.ReleaseIgnored{}, &1.data))
    assert call(home, Sync, :quarantine, []) == []

    stop(home)
    stop(second)
  end

  test "a diverged node stays fenced across restarts while home keeps writing" do
    {home, second} = pair()
    _ = assign!(home, second, "a:*")
    _ = assign!(home, second, "b:*")
    {:ok, _} = call(second, Ownership, :release, [hd(call(second, Ownership, :list, [])).generation])
    wait_until(fn -> length(call(home, Ownership, :list, [])) == 1 end)
    disconnect(home, second)
    {:ok, _} = call(home, Ownership, :revoke_node, ["secondary-node-1"])

    call(second, Failpoint, :set, [:import_before_commit, :halt])
    ref = Process.monitor(second.peer)
    connect(home, second)
    assert_receive {:DOWN, ^ref, :process, _, _}, 10_000

    {:ok, second} = restart(second)
    refute status(second).diverged
    connect(home, second)
    wait_until(fn -> status(second).diverged end)

    state = call(second, Sync, :state, [])
    assert map_size(state.revoked) == 1
    assert Map.has_key?(state.retired, "secondary-node-1")
    cursor = status(second).peers["main-node"].cursor

    :ok = append(home, "orders:1", notes(["after"]))
    stop(second)
    {:ok, second} = restart(second)
    connect(home, second)
    Process.sleep(1_500)
    assert status(second).peers["main-node"].cursor == cursor
    assert read(second, "orders:1") == []

    stop(home)
    stop(second)
  end
end
