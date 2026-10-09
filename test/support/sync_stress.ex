defmodule EventstoreSqlite.SyncStress do
  @moduledoc """
  A seeded, randomized stress run of two-node sync.

  Both nodes write continuously to the regions they own, while the run hands
  regions back and forth, archives streams, partitions the nodes, kills
  replicators and kills nodes. Every acknowledged write is recorded here,
  outside the nodes. At the end the run quiesces and checks the invariants,
  then forces a reclaim of a writing, partitioned node and checks the
  quarantine.

  Options: `:seed`, `:seconds`, `:writers_per_region`, `:max_partition_ms`.
  """

  import EventstoreSqlite.Cluster

  alias EventstoreSqlite.Cluster.Remote
  alias EventstoreSqlite.Ownership
  alias EventstoreSqlite.Sync

  @regions ["r0:", "r1:", "r2:", "r3:"]
  @home_region "h:"

  def run(opts \\ []) do
    seed = Keyword.get(opts, :seed, :rand.uniform(1_000_000))
    :rand.seed(:exsss, {seed, seed, seed})
    seconds = Keyword.get(opts, :seconds, 300)
    started = System.monotonic_time(:millisecond)

    {home, second} = pair()

    run = %{
      seed: seed,
      deadline: started + seconds * 1_000,
      started: started,
      nodes: %{home: home, second: second},
      owners: Map.new(@regions, &{&1, :home}),
      pending: %{},
      coordinators: [],
      acked: %{home: [], second: []},
      partitioned_until: nil,
      next_verify: started + 10_000,
      lag: [],
      handovers: [],
      violations: [],
      ops: %{},
      writers_per_region: Keyword.get(opts, :writers_per_region, 3),
      max_partition_ms: Keyword.get(opts, :max_partition_ms, 30_000),
      collectors: %{}
    }

    run =
      run
      |> start_writers(:home, @home_region)
      |> then(&Enum.reduce(@regions, &1, fn region, run -> start_writers(run, :home, region) end))
      |> start_collectors()
      |> loop()
      |> quiesce()
      |> forced_phase()

    stop(run.nodes.home)
    stop(run.nodes.second)
    report(run)
  end

  defp streams(region, run), do: Enum.map(1..run.writers_per_region, &"#{region}#{&1}")

  defp node(run, key), do: Map.fetch!(run.nodes, key)

  defp patient(fun, attempts \\ 20) do
    fun.()
  rescue
    error in [DBConnection.ConnectionError, ErlangError] ->
      if attempts == 0, do: reraise(error, __STACKTRACE__)
      Process.sleep(250)
      patient(fun, attempts - 1)
  end

  defp start_writers(run, key, region) do
    coordinator = call(node(run, key), Remote, :start_writers, [streams(region, run), 15])
    %{run | coordinators: [{key, region, coordinator} | run.coordinators]}
  end

  defp start_collectors(run) do
    collectors = Map.new([:home, :second], fn key -> {key, call(node(run, key), Remote, :collect, ["$all"])} end)
    %{run | collectors: collectors}
  end

  defp loop(run) do
    run = run |> drain() |> heal_if_due() |> start_pending_writers() |> sample_lag() |> verify_if_due()

    if System.monotonic_time(:millisecond) >= run.deadline do
      run
    else
      Process.sleep(Enum.random(100..600))
      run |> act(pick_action(run)) |> loop()
    end
  end

  defp pick_action(%{partitioned_until: nil}) do
    Enum.random(
      List.duplicate(:assign, 4) ++
        List.duplicate(:reclaim, 4) ++
        List.duplicate(:archive, 3) ++
        List.duplicate(:partition, 2) ++
        List.duplicate(:kill_replicator, 2) ++ [:kill_second, :kill_home]
    )
  end

  defp pick_action(_partitioned), do: Enum.random([:archive, :archive, :reclaim, :kill_replicator, :kill_second])

  defp count(run, action), do: %{run | ops: Map.update(run.ops, action, 1, &(&1 + 1))}

  defp act(run, :assign) do
    case Enum.filter(run.owners, &(elem(&1, 1) == :home)) do
      [] ->
        run

      home_regions ->
        {region, :home} = Enum.random(home_regions)

        case call(run.nodes.home, Ownership, :assign, ["#{region}*", "secondary-node-1"]) do
          {:ok, generation} ->
            count(%{run | owners: Map.put(run.owners, region, {:assigning, generation})}, :assign)

          {:error, reason} ->
            violation(run, {:assign_failed, region, reason})
        end
    end
  end

  defp act(run, :reclaim) do
    case Enum.filter(run.owners, &match?({_, {:second, _}}, &1)) do
      [] ->
        run

      second_regions ->
        {region, {:second, generation}} = Enum.random(second_regions)
        reclaim(run, region, generation)
    end
  end

  defp act(run, :archive) do
    region = Enum.random([@home_region | @regions])
    stream = Enum.random(streams(region, run))

    owner =
      case Map.get(run.owners, region, :home) do
        :home -> :home
        {:second, _} -> :second
        _ -> nil
      end

    if owner do
      case call(node(run, owner), EventstoreSqlite, :archive_stream, [stream]) do
        :ok -> count(run, :archive)
        {:error, reason} when reason in [:stream_not_found, :not_owner] -> run
        other -> violation(run, {:archive_failed, stream, other})
      end
    else
      run
    end
  end

  defp act(run, :partition) do
    disconnect(run.nodes.home, run.nodes.second)
    duration = Enum.random(100..run.max_partition_ms)
    count(%{run | partitioned_until: System.monotonic_time(:millisecond) + duration}, :partition)
  end

  defp act(run, :kill_replicator) do
    key = Enum.random([:home, :second])
    peer = if key == :home, do: "secondary-node-1", else: "main-node"
    call(node(run, key), Remote, :kill_replicator, [peer])
    count(run, :kill_replicator)
  end

  defp act(run, :kill_second), do: run |> restart_node(:second) |> count(:kill_second)
  defp act(run, :kill_home), do: run |> restart_node(:home) |> count(:kill_home)

  defp reclaim(run, region, generation) do
    started = System.monotonic_time(:millisecond)

    case call(run.nodes.home, Ownership, :reclaim, [generation, [timeout: 10_000]], 60_000) do
      :ok ->
        took = System.monotonic_time(:millisecond) - started
        run = %{run | owners: Map.put(run.owners, region, :home), handovers: [took | run.handovers]}
        run |> start_writers(:home, region) |> count(:reclaim)

      {:error, reason} when reason in [:timeout, :unreachable] ->
        count(run, :reclaim_retry_later)

      {:error, reason} ->
        violation(run, {:reclaim_failed, region, generation, reason})
    end
  end

  defp restart_node(run, key) do
    run = drain(run)
    kill(node(run, key))
    {:ok, restarted} = restart(node(run, key))
    nodes = Map.put(run.nodes, key, restarted)
    other = if key == :home, do: nodes.second, else: nodes.home
    if run.partitioned_until == nil, do: connect(restarted, other)

    run = %{
      run
      | nodes: nodes,
        coordinators: Enum.reject(run.coordinators, &(elem(&1, 0) == key)),
        collectors: Map.put(run.collectors, key, call(restarted, Remote, :collect, ["$all"]))
    }

    regions =
      if key == :home do
        [@home_region | for({region, :home} <- run.owners, do: region)]
      else
        for {region, {:second, _}} <- run.owners, do: region
      end

    Enum.reduce(regions, run, &start_writers(&2, key, &1))
  end

  defp heal_if_due(%{partitioned_until: nil} = run), do: run

  defp heal_if_due(run) do
    if System.monotonic_time(:millisecond) >= run.partitioned_until do
      connect(run.nodes.home, run.nodes.second)
      %{run | partitioned_until: nil}
    else
      run
    end
  end

  defp start_pending_writers(run) do
    assigned = MapSet.new(patient(fn -> call(run.nodes.second, Ownership, :list, []) end), & &1.generation)

    Enum.reduce(run.owners, run, fn
      {region, {:assigning, generation}}, run ->
        if MapSet.member?(assigned, generation) do
          run = %{run | owners: Map.put(run.owners, region, {:second, generation})}
          start_writers(run, :second, region)
        else
          run
        end

      _, run ->
        run
    end)
  end

  defp drain(run) do
    Enum.reduce(run.coordinators, run, fn {key, _region, coordinator}, run ->
      {acked, _running} = call(node(run, key), Remote, :drain_acks, [coordinator])
      %{run | acked: Map.update!(run.acked, key, &(&1 ++ acked))}
    end)
  catch
    :exit, _ -> run
  end

  defp sample_lag(run) do
    lags =
      for {key, peer} <- [home: "secondary-node-1", second: "main-node"],
          lag = get_in(patient(fn -> status(node(run, key)) end), [:peers, peer, :lag]),
          is_integer(lag),
          do: lag

    %{run | lag: lags ++ run.lag}
  end

  defp verify_if_due(run) do
    now = System.monotonic_time(:millisecond)

    if now >= run.next_verify and run.partitioned_until == nil do
      run = %{run | next_verify: now + 10_000}

      case call(run.nodes.home, Sync, :verify, ["secondary-node-1", :prefix], 120_000) do
        {:error, {:not_connected, _}} -> run
        {:error, :not_connected} -> run
        {:error, forks} -> violation(run, {:fork, forks})
        _ok_or_lag -> count(run, :verify_prefix)
      end
    else
      run
    end
  end

  defp violation(run, violation), do: %{run | violations: [violation | run.violations]}

  defp quiesce(run) do
    run = if run.partitioned_until, do: heal_now(run), else: run
    run = settle_ownership(run)
    run = stop_all_writers(run)
    %{home: home, second: second} = run.nodes

    run = check_converged(run, home, second)
    run = check_halts(run)
    run = check_acked(run, run.acked.home ++ run.acked.second)
    run = check_all_stream(run)
    check_collectors(run)
  end

  defp check_converged(run, home, second) do
    started = System.monotonic_time(:millisecond)
    caught_up(home, second, 120_000)
    caught_up(second, home, 120_000)
    run = %{run | ops: Map.put(run.ops, :quiesce_catch_up_ms, System.monotonic_time(:millisecond) - started)}

    case wait_for_strict_verify(home, 20) do
      :ok ->
        run

      {:error, [{stream, _} | _]} = other ->
        home_dump = call(home, Remote, :stream_dump, [stream])
        second_dump = call(second, Remote, :stream_dump, [stream])
        home_ids = MapSet.new(home_dump.live ++ home_dump.archived, &List.last/1)
        second_ids = MapSet.new(second_dump.live ++ second_dump.archived, &List.last/1)
        only_home = MapSet.difference(home_ids, second_ids)
        acked_by = fn key -> Enum.filter(run.acked[key], &MapSet.member?(only_home, elem(&1, 2))) end

        summary = fn node -> node |> call(EventstoreSqlite.Sync.Verify, :summaries, [], 120_000) |> Map.get(stream) end
        summaries_now = {summary.(home), summary.(second)}
        verify_again = call(home, Sync, :verify, ["secondary-node-1", :strict], 120_000)

        violation(run, {
          :not_converged,
          other,
          %{
            summaries_now: summaries_now,
            verify_again: verify_again,
            statuses: {status(home), status(second)},
            stream: stream,
            home_counts: {length(home_dump.live), length(home_dump.archived)},
            second_counts: {length(second_dump.live), length(second_dump.archived)},
            only_on_home: MapSet.to_list(only_home),
            acked_by_home: acked_by.(:home),
            acked_by_second: acked_by.(:second),
            home_tables: call(home, Remote, :sync_tables, []),
            second_tables: call(second, Remote, :sync_tables, [])
          }
        })

      other ->
        violation(run, {:not_converged, other, status(home), status(second)})
    end
  rescue
    error in ExUnit.AssertionError ->
      cursor = status(home).peers["secondary-node-1"].cursor

      violation(run, {
        :not_caught_up,
        error.message,
        status(home),
        status(second),
        %{
          home_replicator: call(home, Remote, :replicator_info, ["secondary-node-1"]),
          second_replicator: call(second, Remote, :replicator_info, ["main-node"]),
          export_from_second: call(second, Remote, :export_as, ["main-node", cursor]),
          home_sees_second: call(home, :pg, :get_members, [EventstoreSqlite.Sync.PG, {:node, "secondary-node-1"}]),
          home_tables: call(home, Remote, :sync_tables, []),
          second_tables: call(second, Remote, :sync_tables, []),
          second_node: second.node
        }
      })
  end

  defp wait_for_strict_verify(home, attempts) do
    case call(home, Sync, :verify, ["secondary-node-1", :strict], 120_000) do
      :ok ->
        :ok

      other when attempts == 0 ->
        other

      _ ->
        Process.sleep(500)
        wait_for_strict_verify(home, attempts - 1)
    end
  end

  defp heal_now(run) do
    connect(run.nodes.home, run.nodes.second)
    %{run | partitioned_until: nil}
  end

  defp settle_ownership(run), do: settle_ownership(run, System.monotonic_time(:millisecond) + 60_000)

  defp settle_ownership(run, deadline) do
    run = start_pending_writers(run)

    cond do
      Enum.all?(run.owners, fn {_region, owner} -> not match?({:assigning, _}, owner) end) ->
        run

      System.monotonic_time(:millisecond) > deadline ->
        violation(run, {:assignment_never_arrived, run.owners, status(run.nodes.home), status(run.nodes.second)})

      true ->
        Process.sleep(100)
        settle_ownership(run, deadline)
    end
  end

  defp stop_all_writers(run) do
    Enum.reduce(run.coordinators, %{run | coordinators: []}, fn {key, _region, coordinator}, run ->
      case call(node(run, key), Remote, :stop_writers, [coordinator]) do
        {acked, _} -> %{run | acked: Map.update!(run.acked, key, &(&1 ++ acked))}
        :timeout -> violation(run, {:writers_didnt_stop, key})
      end
    end)
  end

  defp check_halts(run) do
    halts =
      for {key, peer} <- [home: "secondary-node-1", second: "main-node"],
          halted = get_in(status(node(run, key)), [:peers, peer, :halted]),
          do: {key, halted}

    if halts == [], do: run, else: violation(run, {:halted, halts})
  end

  defp check_acked(run, acked) do
    acked_ids = MapSet.new(acked, &elem(&1, 2))

    Enum.reduce([:home, :second], run, fn key, run ->
      missing = MapSet.difference(acked_ids, call(node(run, key), Remote, :event_ids, []))
      if MapSet.size(missing) == 0, do: run, else: violation(run, {:lost_acked_writes, key, MapSet.size(missing)})
    end)
  end

  defp check_all_stream(run) do
    Enum.reduce([:home, :second], run, fn key, run ->
      check = call(node(run, key), Remote, :all_stream_check, [])

      if check.all_rows == check.distinct_ids and check.all_rows == check.live_rows do
        run
      else
        violation(run, {:all_stream, key, check})
      end
    end)
  end

  defp check_collectors(run) do
    Enum.reduce(run.collectors, run, fn {key, collector}, run ->
      received = call(node(run, key), Remote, :received, [collector])
      positions = for {position, _id, _data} <- received, do: position
      ids = for {_position, id, _data} <- received, do: id

      cond do
        positions != Enum.sort(positions) -> violation(run, {:all_out_of_order, key})
        length(Enum.uniq(positions)) != length(positions) -> violation(run, {:all_duplicate_positions, key})
        length(Enum.uniq(ids)) != length(ids) -> violation(run, {:all_duplicate_events, key})
        true -> run
      end
    end)
  end

  defp forced_phase(run) do
    %{home: home, second: second} = run.nodes
    {:ok, generation} = call(home, Ownership, :assign, ["forced:*", "secondary-node-1"])
    wait_until(fn -> Enum.any?(call(second, Ownership, :list, []), &(&1.generation == generation)) end)

    writers = call(second, Remote, :start_writers, [["forced:1", "forced:2"], 2])
    Process.sleep(500)
    disconnect(home, second)
    Process.sleep(1_000)

    {:ok, _} = call(home, Ownership, :revoke_node, ["secondary-node-1"])
    home_writers = call(home, Remote, :start_writers, [["forced:1", "forced:2"], 2])
    Process.sleep(1_000)

    {home_acked, _} = call(home, Remote, :stop_writers, [home_writers])
    {second_acked, _} = call(second, Remote, :stop_writers, [writers])
    connect(home, second)

    wait_until(fn -> status(home).peers["secondary-node-1"].state == :drained end, 30_000)
    wait_until(fn -> status(second).diverged end, 30_000)

    home_ids = call(home, Remote, :event_ids, [])

    quarantined_ids =
      home
      |> call(Sync, :quarantine, [])
      |> Enum.flat_map(fn quarantined -> Enum.map(quarantined.entry.events, & &1.id) end)
      |> MapSet.new()

    second_ids = MapSet.new(second_acked, &elem(&1, 2))

    run =
      cond do
        not MapSet.disjoint?(quarantined_ids, home_ids) ->
          violation(run, :quarantined_events_also_applied)

        not MapSet.subset?(quarantined_ids, second_ids) ->
          violation(run, :quarantine_holds_writes_the_second_node_never_acked)

        not MapSet.subset?(second_ids, MapSet.union(home_ids, quarantined_ids)) ->
          violation(run, :acked_write_neither_applied_nor_quarantined)

        not MapSet.subset?(MapSet.new(home_acked, &elem(&1, 2)), home_ids) ->
          violation(run, :home_lost_writes_in_forced_phase)

        true ->
          run
      end

    run = %{run | ops: Map.put(run.ops, :quarantined, MapSet.size(quarantined_ids))}

    case call(home, Sync, :remove_peer, ["secondary-node-1"]) do
      :ok -> :ok
      other -> throw({:remove_peer_failed, other})
    end

    [[log]] =
      call(home, Ecto.Adapters.SQL, :query!, [EventstoreSqlite.RepoRead, "SELECT count(*) FROM sync_log", []]).rows

    if log == 0, do: run, else: violation(run, {:log_not_empty_after_removal, log})
  catch
    {:remove_peer_failed, other} -> violation(run, {:remove_peer_failed, other})
  end

  defp report(run) do
    elapsed = (System.monotonic_time(:millisecond) - run.started) / 1_000
    acked = length(run.acked.home) + length(run.acked.second)
    lag = Enum.sort(run.lag)

    %{
      seed: run.seed,
      seconds: Float.round(elapsed, 1),
      acked_writes: acked,
      writes_per_second: Float.round(acked / elapsed, 1),
      lag_entries: %{p50: percentile(lag, 0.5), p99: percentile(lag, 0.99), max: List.last(lag)},
      handover_ms: %{count: length(run.handovers), max: Enum.max(run.handovers, fn -> nil end)},
      ops: run.ops,
      violations: Enum.reverse(run.violations)
    }
  end

  defp percentile([], _), do: nil
  defp percentile(sorted, p), do: Enum.at(sorted, min(length(sorted) - 1, trunc(p * length(sorted))))
end
