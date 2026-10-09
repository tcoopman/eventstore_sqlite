defmodule EventstoreSqlite.Sync.ImportTest do
  use ExUnit.Case
  use EventstoreSqlite.DataCase
  use EventstoreSqlite.SyncCase

  import EventstoreSqlite.SyncEntries

  alias EventstoreSqlite.Sync.Failpoint
  alias EventstoreSqlite.Sync.Import

  defp import!(origin, entries) do
    head = entries |> Enum.map(& &1.seq) |> Enum.max(fn -> 0 end)
    Import.import_entries(origin, entries, %{head: head, diverged: false})
  end

  defp as_secondary(_context) do
    record!([
      %SystemEvents.SyncEnabled{node_id: "home", home: "home", sync_id: "group"},
      %SystemEvents.SnapshotClaimed{snapshot_id: "s", node_id: "test-node", snapshot_of: "home", cursor: 0}
    ])

    :ok
  end

  defp as_home(_context) do
    :ok = Sync.enable("test-node")
    record!(%SystemEvents.PeerAdded{node_id: "peer", pinned_seq: 0})
    :ok
  end

  setup do
    on_exit(&Failpoint.clear_all/0)
  end

  defp texts(stream), do: Enum.map(EventstoreSqlite.read_stream_forward(stream), & &1.data.text)

  defp cursor(origin), do: Import.cursor(EventstoreSqlite.RepoWrite, origin)

  describe "appends from the home node" do
    setup :as_secondary

    test "are stored with their original ids, timestamps and bytes, and reach subscribers" do
      :ok = EventstoreSqlite.subscribe_to_stream(self(), "orders:1")
      entry = append_entry(1, "orders:1", 0, ["a", "b"])
      metadata = :erlang.term_to_binary(%{correlation_id: "c"})
      entry = put_in(entry.events, [hd(entry.events), raw_event("b", metadata: metadata)])

      assert {:ok, %{cursor: 1}} = import!("home", [entry])

      assert query(
               "SELECT id, type, data, metadata, inserted_at, typeof(data), typeof(metadata) FROM events WHERE type = 'Elixir.EventstoreSqlite.Test.Note' ORDER BY id"
             ) ==
               entry.events
               |> Enum.sort_by(& &1.id)
               |> Enum.map(
                 &[
                   &1.id,
                   &1.type,
                   &1.data,
                   &1.metadata,
                   &1.inserted_at,
                   "blob",
                   if(&1.metadata, do: "blob", else: "null")
                 ]
               )

      assert_receive {:events, events}

      assert Enum.map(events, &{&1.id, &1.stream_version, &1.data.text}) == [
               {Enum.at(entry.events, 0).id, 0, "a"},
               {Enum.at(entry.events, 1).id, 1, "b"}
             ]

      assert Enum.map(EventstoreSqlite.read_stream_forward("$all"), & &1.original_stream_id) == ["orders:1", "orders:1"]
      assert cursor("home") == 1
      assert log_rows() == []
    end

    test "an entry imported twice is applied once" do
      entries = [append_entry(1, "a", 0, "x"), append_entry(2, "a", 1, "y")]
      {:ok, _} = import!("home", entries)
      assert {:ok, %{cursor: 2}} = import!("home", entries)
      assert texts("a") == ["x", "y"]
    end

    test "a gap halts replication from that origin until it is resumed" do
      assert {:halt, {:gap, 0, 2}, _} = import!("home", [append_entry(2, "a", 0, "x")])
      assert Sync.state().halted == %{"home" => {:gap, 0, 2}}
      assert import!("home", [append_entry(1, "a", 0, "x")]) == {:fenced, {:halted, {:gap, 0, 2}}}

      :ok = Sync.resume("home")
      assert {:ok, %{cursor: 1}} = import!("home", [append_entry(1, "a", 0, "x")])
    end

    test "a version conflict halts; entries before it in the batch are kept" do
      entries = [append_entry(1, "a", 0, "x"), append_entry(2, "a", 5, "y")]
      assert {:halt, {:version_conflict, "a", 1, 5}, %{cursor: 1}} = import!("home", entries)
      assert texts("a") == ["x"]
      assert cursor("home") == 1
    end

    test "an entry larger than a transaction's bound is applied whole" do
      texts = Enum.map(1..1_500, &"e#{&1}")
      entries = [append_entry(1, "a", 0, "x"), append_entry(2, "big", 0, texts), append_entry(3, "a", 1, "y")]

      assert {:ok, %{cursor: 3}} = import!("home", entries)
      assert length(texts("big")) == 1_500
    end

    test "an append from home to a stream assigned elsewhere breaks the single-writer rule" do
      entries = [ownership_entry(1, {:assigned, "venue:*", "test-node"}), append_entry(2, "venue:1", 0, "x")]

      assert {:halt, {:ownership_violation, {:not_owner, "venue:1", 0}}, %{cursor: 1}} = import!("home", entries)
      assert Sync.state().owners == %{1 => %{selector: "venue:*", owner: "test-node"}}
    end

    test "an archive is applied at the same version and ends local subscriptions" do
      {:ok, _} = import!("home", [append_entry(1, "a", 0, ["x", "y"])])
      :ok = EventstoreSqlite.subscribe_to_stream(self(), "a")
      assert_receive {:events, _}

      assert {:ok, %{cursor: 2}} = import!("home", [archive_entry(2, "a", 2)])

      assert_receive {:stream_archived, "a"}
      assert EventstoreSqlite.read_stream_forward("a") == []

      assert [%{data: %SystemEvents.StreamArchived{stream_id: "a", event_count: 2}}] =
               EventstoreSqlite.read_stream_forward("$archives")

      assert {:ok, %{cursor: 2}} = import!("home", [archive_entry(2, "a", 2)])
      assert query("SELECT count(*) FROM archived_streams") == [[1]]
    end

    test "an archive at another version halts" do
      {:ok, _} = import!("home", [append_entry(1, "a", 0, ["x", "y"])])

      assert {:halt, {:archive_conflict, "a", :wrong_expected_version}, _} = import!("home", [archive_entry(2, "a", 5)])
      assert texts("a") == ["x", "y"]
      assert cursor("home") == 1
    end

    test "a raise before an archive commits leaves nothing archived and the cursor unchanged" do
      {:ok, _} = import!("home", [append_entry(1, "a", 0, "x")])
      Failpoint.set(:archive_before_commit, {:once, {:raise, "boom"}})

      assert_raise RuntimeError, "boom", fn -> import!("home", [archive_entry(2, "a", 1)]) end
      assert texts("a") == ["x"]
      assert cursor("home") == 1
    end

    test "a raise after an archive commits restarts the subscription process, dropping every registration" do
      {:ok, _} = import!("home", [append_entry(1, "a", 0, "x")])
      :ok = EventstoreSqlite.subscribe_to_stream(self(), "a")
      assert_receive {:events, _}
      subscriptions = Process.whereis(EventstoreSqlite.Subscriptions)
      Failpoint.set(:archive_after_commit, {:once, {:raise, "boom"}})

      catch_exit(import!("home", [archive_entry(2, "a", 1)]))

      assert cursor("home") == 2
      wait_until(fn -> Process.whereis(EventstoreSqlite.Subscriptions) not in [nil, subscriptions] end)
      {:ok, _} = import!("home", [append_entry(3, "a", 0, "reused")])
      refute_receive {:events, _}, 400
    end

    test "events committed by an import whose notification was lost still reach subscribers" do
      :ok = EventstoreSqlite.subscribe_to_stream(self(), "a")
      Failpoint.set(:import_after_commit, {:once, {:raise, "lost"}})

      assert_raise RuntimeError, "lost", fn -> import!("home", [append_entry(1, "a", 0, "x")]) end

      assert_receive {:events, [%{data: %{text: "x"}}]}, 1_000
    end
  end

  describe "entries from a peer on the home node" do
    setup :as_home

    test "appends under an active generation of that peer are applied, within its selector only" do
      generation = assign!("venue:*", "peer")

      assert {:ok, %{cursor: 1}} = import!("peer", [append_entry(1, "venue:1", 0, "x", generation)])
      assert texts("venue:1") == ["x"]

      assert {:halt, {:ownership_violation, {:not_owner, "orders:1", ^generation}}, _} =
               import!("peer", [append_entry(2, "orders:1", 0, "y", generation)])
    end

    test "generation 0 from a peer that isn't home breaks the single-writer rule" do
      assert {:halt, {:ownership_violation, {:not_owner, "orders:1", 0}}, _} =
               import!("peer", [append_entry(1, "orders:1", 0, "y")])
    end

    test "only the home node may assign or revoke" do
      assert {:halt, {:ownership_violation, :assign_from_non_home, 1}, _} =
               import!("peer", [ownership_entry(1, {:assigned, "x:*", "peer"})])

      :ok = Sync.resume("peer")

      assert {:halt, {:ownership_violation, :revoke_from_non_home, 1}, _} =
               import!("peer", [ownership_entry(1, {:node_revoked, "test-node", [], 0})])
    end

    test "a release of an active generation hands it back; a stale or unknown release is not applied" do
      generation = assign!("venue:*", "peer")

      assert {:ok, _} = import!("peer", [ownership_entry(1, {:released, generation})])
      assert Sync.state().owners == %{}
      assert Sync.state().released == %{generation => %{owner: "peer", release_seq: 1}}

      assert {:ok, _} = import!("peer", [ownership_entry(2, {:released, generation})])

      assert [%{data: %SystemEvents.ReleaseIgnored{generation: ^generation}}] =
               "$ownership" |> EventstoreSqlite.read_stream_forward() |> Enum.take(-1)

      assert {:halt, {:ownership_violation, {:release_of_unowned_generation, 99}, 3}, _} =
               import!("peer", [ownership_entry(3, {:released, 99})])
    end

    test "entries under a revoked generation are quarantined, archives too" do
      generation = assign!("venue:*", "peer")
      {:ok, _} = import!("peer", [append_entry(1, "venue:1", 0, "kept", generation)])

      record!([
        %SystemEvents.OwnershipRevoked{generation: generation, selector: "venue:*", from: "peer", cutoff: 1},
        %SystemEvents.NodeRetired{node_id: "peer", revoke_seq: 9}
      ])

      entries = [append_entry(2, "venue:1", 1, "late", generation), archive_entry(3, "venue:1", 2, generation)]
      assert {:ok, %{cursor: 3, quarantined: 2}} = import!("peer", entries)

      assert texts("venue:1") == ["kept"]
      assert [%{origin: "peer", seq: 2, reason: "revoked_generation"}, %{seq: 3}] = Sync.quarantine()
      assert hd(Sync.quarantine()).entry.events |> hd() |> Map.get(:data) |> :erlang.binary_to_term() == note("late")
    end
  end

  describe "a revocation of this node" do
    setup :as_secondary

    test "makes it diverged, stops the batch at the revocation, and fences everything after" do
      entries = [
        ownership_entry(1, {:assigned, "venue:*", "test-node"}),
        ownership_entry(2, {:node_revoked, "test-node", [{1, "venue:*"}], 0}),
        append_entry(3, "orders:1", 0, "after")
      ]

      assert {:diverged, %{cursor: 2}} = import!("home", entries)

      state = Sync.state()
      assert state.diverged == %{revoked_by: "home", revoke_seq: 2}
      assert state.retired == %{"test-node" => 2}
      assert state.revoked == %{1 => %{selector: "venue:*", from: "test-node", cutoff: 0}}
      assert EventstoreSqlite.read_stream_forward("orders:1") == []

      assert import!("home", [append_entry(3, "orders:1", 0, "after")]) == {:fenced, :diverged}
      assert EventstoreSqlite.append_to_stream("venue:1", [note("x")]) == {:error, :diverged}
      assert Sync.resume("home") == {:error, :diverged}
    end

    test "diverges a node that already released everything" do
      record!(%SystemEvents.OwnershipReleased{generation: 1, from: "test-node", release_seq: 1})

      assert {:diverged, _} = import!("home", [ownership_entry(1, {:node_revoked, "test-node", [], 0})])
      assert Sync.state().diverged
    end
  end

  defp assign!(selector, to) do
    seq = EventstoreSqlite.Sync.Log.head(EventstoreSqlite.RepoWrite) + 1
    record!(%SystemEvents.OwnershipAssigned{selector: selector, to: to, generation: seq})
    seq
  end

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition never became true")
      true -> retry_after_pause(fun, attempts)
    end
  end

  defp retry_after_pause(fun, attempts) do
    Process.sleep(20)
    wait_until(fun, attempts - 1)
  end
end
