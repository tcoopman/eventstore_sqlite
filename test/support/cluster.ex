defmodule EventstoreSqlite.Cluster do
  @moduledoc """
  Runs eventstore_sqlite nodes as separate BEAMs for two-node tests.

  Each node is a `:peer` controlled over its standard I/O, so the test's
  control channel doesn't use distribution, and it is started with
  `dist_auto_connect never`: the nodes only see each other after `connect/2`,
  and a `disconnect/2` lasts until the next `connect/2`.
  """

  defstruct [:node_id, :db, :peer, :node]

  @cookie ~c"eventstore_sqlite_cluster"

  def start(node_id, opts \\ []) do
    db = Keyword.get_lazy(opts, :db, &new_db_path/0)
    name = :"esq_#{String.replace(node_id, ~r/\W/, "_")}_#{System.unique_integer([:positive])}"
    paths = Enum.flat_map(:code.get_path(), &[~c"-pa", &1])

    {:ok, peer, node} =
      :peer.start(%{
        name: name,
        connection: :standard_io,
        args: [~c"-setcookie", @cookie, ~c"-kernel", ~c"dist_auto_connect", ~c"never" | paths]
      })

    cluster_node = %__MODULE__{node_id: node_id, db: db, peer: peer, node: node}
    env = env(db, Keyword.get(opts, :configured_node_id, node_id))

    case call(cluster_node, EventstoreSqlite.Cluster.Remote, :boot, [env], 60_000) do
      :ok ->
        {:ok, cluster_node}

      {:error, reason} ->
        stop(cluster_node)
        {:error, reason}
    end
  end

  def start!(node_id, opts \\ []) do
    {:ok, node} = start(node_id, opts)
    node
  end

  def db_dir, do: Path.join(System.tmp_dir!(), "eventstore_sqlite_cluster")

  def new_db_path do
    File.mkdir_p!(db_dir())
    Path.join(db_dir(), "#{Base.url_encode64(:crypto.strong_rand_bytes(9))}.db")
  end

  def remove_db(path), do: Enum.each(["", "-wal", "-shm"], &File.rm(path <> &1))

  defp env(db, node_id) do
    config =
      :eventstore_sqlite
      |> Application.get_all_env()
      |> Keyword.update!(EventstoreSqlite.RepoWrite, &Keyword.put(&1, :database, db))
      |> Keyword.update!(EventstoreSqlite.RepoRead, &Keyword.put(&1, :database, db))
      |> Keyword.put(:sync, node_id: node_id)

    [eventstore_sqlite: config]
  end

  def call(%__MODULE__{peer: peer}, module, fun, args, timeout \\ 30_000) do
    :peer.call(peer, module, fun, args, timeout)
  end

  def connect(a, b), do: true = call(a, Node, :connect, [b.node])
  def disconnect(a, b), do: call(a, :erlang, :disconnect_node, [b.node])

  def stop(%__MODULE__{peer: peer}) do
    :peer.stop(peer)
  catch
    :exit, _ -> :ok
  end

  @doc """
  Kills the node at once, as `kill -9` would: no shutdown, no flushing.
  """
  def kill(%__MODULE__{peer: peer}) do
    ref = Process.monitor(peer)
    :peer.cast(peer, :erlang, :halt, [137, [flush: false]])

    receive do
      {:DOWN, ^ref, :process, ^peer, _} -> :ok
    after
      10_000 -> raise "the node didn't die"
    end
  end

  def restart(%__MODULE__{} = node, opts \\ []) do
    start(node.node_id, Keyword.put(opts, :db, node.db))
  end

  def append(node, stream, events, expected_version \\ :any_version) do
    call(node, EventstoreSqlite, :append_to_stream, [stream, events, expected_version])
  end

  def read(node, stream) do
    call(node, EventstoreSqlite, :read_stream_forward, [stream, [count: nil]])
  end

  def texts(node, stream), do: node |> read(stream) |> Enum.map(& &1.data.text)

  def status(node), do: call(node, EventstoreSqlite.Sync, :status, [])

  def wait_until(fun, timeout \\ 10_000) do
    wait_until_deadline(fun, System.monotonic_time(:millisecond) + timeout)
  end

  defp wait_until_deadline(fun, deadline) do
    case fun.() do
      result when result not in [nil, false] ->
        result

      result ->
        if System.monotonic_time(:millisecond) > deadline do
          raise ExUnit.AssertionError, message: "condition not met in time, last result: #{inspect(result)}"
        else
          Process.sleep(25)
          wait_until_deadline(fun, deadline)
        end
    end
  end

  @doc """
  Waits until `node` has pulled everything `peer` reported.
  """
  def caught_up(node, peer, timeout \\ 10_000) do
    wait_until(
      fn ->
        case status(node).peers[peer.node_id] do
          %{lag: 0, peer_head: head} = status when is_integer(head) -> head == status(peer).head and status
          _ -> false
        end
      end,
      timeout
    )
  end

  @doc """
  Waits until both nodes have pulled everything from each other and their
  histories are identical.
  """
  def converged(a, b) do
    caught_up(a, b)
    caught_up(b, a)
    wait_until(fn -> call(a, EventstoreSqlite.Sync, :verify, [b.node_id, :strict]) == :ok end)
  end

  @doc """
  Starts a home node, snapshots it for a second node, and starts that node on
  the copy. Returns `{home, second}`, connected.
  """
  def pair(home_id \\ "main-node", second_id \\ "secondary-node-1", opts \\ []) do
    home = start!(home_id)
    :ok = call(home, EventstoreSqlite.Sync, :enable, [home_id])
    Keyword.get(opts, :before_snapshot, fn _ -> :ok end).(home)
    path = new_db_path()
    {:ok, _} = call(home, EventstoreSqlite.Sync, :snapshot, [path, [peer: second_id]])
    second = start!(second_id, db: path)
    connect(home, second)
    {home, second}
  end
end

defmodule EventstoreSqlite.Cluster.Remote do
  @moduledoc """
  Runs on a cluster node.
  """

  alias Ecto.Adapters.SQL
  alias EventstoreSqlite.Sync.Export
  alias EventstoreSqlite.Test.Note

  def boot(env) do
    Application.load(:eventstore_sqlite)
    for {app, config} <- env, {key, value} <- config, do: Application.put_env(app, key, value)
    Logger.configure(level: :warning)

    {:ok, _, _} =
      Ecto.Migrator.with_repo(EventstoreSqlite.RepoWrite, &Ecto.Migrator.run(&1, :up, all: true, log: false))

    case Application.ensure_all_started(:eventstore_sqlite) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def notes(texts), do: Enum.map(List.wrap(texts), &%Note{text: &1})

  @doc """
  Subscribes a process on this node that keeps everything it receives, for
  `received/1`.
  """
  def collect(stream) do
    parent = self()

    pid =
      spawn(fn ->
        :ok = EventstoreSqlite.subscribe_to_stream(self(), stream)
        send(parent, :subscribed)
        collect_loop([])
      end)

    receive do
      :subscribed -> pid
    end
  end

  defp collect_loop(received) do
    receive do
      {:events, events} ->
        collect_loop(received ++ Enum.map(events, &{&1.stream_version, &1.id, &1.data}))

      {:stream_archived, _} = message ->
        collect_loop(received ++ [message])

      {:received, from} ->
        send(from, {:received, received})
        collect_loop(received)
    end
  end

  @doc """
  Starts one writer per stream. Each appends one event at a time with an
  expected version, and records every append that returned `:ok`. A writer
  stops at `{:error, :not_owner}` or `{:error, :diverged}`, or when
  `stop_writers/1` is called. Returns the coordinator's pid.
  """
  def start_writers(streams, pause \\ 0) do
    spawn(fn ->
      coordinator = self()
      writers = Enum.map(streams, fn stream -> spawn_link(fn -> write_loop(coordinator, stream, nil, pause) end) end)
      coordinate(writers, [], %{})
    end)
  end

  defp write_loop(coordinator, stream, version, pause) do
    receive do
      :stop -> send(coordinator, {:done, self(), stream, :stopped})
    after
      pause ->
        version = version || current_version(stream)
        id = Ecto.UUID.generate()
        event = %EventstoreSqlite.NewEvent{id: id, data: %Note{text: "#{stream}@#{version}"}}

        case safe_append(stream, event, version) do
          :raised ->
            write_loop(coordinator, stream, nil, pause)

          :ok ->
            send(coordinator, {:acked, stream, version, id})
            write_loop(coordinator, stream, version + 1, pause)

          {:error, :wrong_expected_version} ->
            write_loop(coordinator, stream, nil, pause)

          {:error, reason} ->
            send(coordinator, {:done, self(), stream, reason})
        end
    end
  end

  defp safe_append(stream, event, version) do
    EventstoreSqlite.append_to_stream(stream, [event], {:version, version})
  rescue
    DBConnection.ConnectionError -> :raised
  end

  defp current_version(stream) do
    case EventstoreSqlite.read_stream_backward(stream, count: 1) do
      [event] -> event.stream_version + 1
      [] -> 0
    end
  end

  defp coordinate(writers, acked, done) do
    receive do
      {:acked, stream, version, id} ->
        coordinate(writers, [{stream, version, id} | acked], done)

      {:done, pid, stream, reason} ->
        coordinate(writers -- [pid], acked, Map.put(done, stream, reason))

      {:drain, from} ->
        send(from, {:drained, Enum.reverse(acked), length(writers)})
        coordinate(writers, [], done)

      {:stop, from} ->
        Enum.each(writers, &send(&1, :stop))
        finish(writers, acked, done, from)
    end
  end

  defp finish([], acked, done, from), do: send(from, {:writers, Enum.reverse(acked), done})

  defp finish(writers, acked, done, from) do
    receive do
      {:acked, stream, version, id} -> finish(writers, [{stream, version, id} | acked], done, from)
      {:done, pid, stream, reason} -> finish(writers -- [pid], acked, Map.put(done, stream, reason), from)
    end
  end

  @doc """
  Stops the writers and returns `{acked, stop_reasons}`, where `acked` lists
  `{stream, version, event_id}` in the order they were acknowledged.
  """
  def stop_writers(coordinator) do
    send(coordinator, {:stop, self()})

    receive do
      {:writers, acked, done} -> {acked, done}
    after
      30_000 -> :timeout
    end
  end

  @doc """
  Returns `{acked, running_writers}`: the writes acknowledged since the last
  drain, and how many writers still run.
  """
  def drain_acks(coordinator) do
    send(coordinator, {:drain, self()})

    receive do
      {:drained, acked, running} -> {acked, running}
    after
      5_000 -> {[], 0}
    end
  end

  def event_ids do
    "SELECT id FROM events"
    |> then(&SQL.query!(EventstoreSqlite.RepoRead, &1, []).rows)
    |> MapSet.new(fn [id] -> id end)
  end

  def all_stream_check do
    [[all_rows, distinct_ids, live_rows]] =
      SQL.query!(
        EventstoreSqlite.RepoRead,
        """
        SELECT (SELECT count(*) FROM stream_events WHERE stream_id = '$all'),
               (SELECT count(DISTINCT event_id) FROM stream_events WHERE stream_id = '$all'),
               (SELECT count(*) FROM stream_events WHERE substr(stream_id, 1, 1) <> '$')
        """,
        []
      ).rows

    %{all_rows: all_rows, distinct_ids: distinct_ids, live_rows: live_rows}
  end

  def replicator_info(peer) do
    case Registry.lookup(EventstoreSqlite.Sync.Registry, peer) do
      [{pid, _}] ->
        info = Process.info(pid, [:current_function, :message_queue_len, :status])
        state = :sys.get_state(pid, 2_000)
        timer = state.timer && Process.read_timer(state.timer)
        %{process: info, state: Map.delete(state, :timer), timer_ms_left: timer}

      [] ->
        :no_replicator
    end
  catch
    kind, reason -> {kind, reason}
  end

  def export_as(peer_id, after_seq) do
    state = EventstoreSqlite.Sync.State.load(EventstoreSqlite.RepoRead)

    request = %{
      protocol: Export.protocol(),
      sync_id: state.sync_id,
      from: peer_id,
      expect: state.node_id,
      after_seq: after_seq,
      max_entries: 5,
      max_bytes: 1_000_000
    }

    case Export.read_only(request) do
      {:ok, response} -> %{head: response.head, seqs: Enum.map(response.entries, & &1.seq)}
      other -> other
    end
  end

  def sync_tables do
    q = &SQL.query!(EventstoreSqlite.RepoRead, &1, []).rows

    %{
      log: q.("SELECT min(seq), max(seq), count(*) FROM sync_log"),
      sequence: q.("SELECT seq FROM sqlite_sequence WHERE name = 'sync_log'"),
      acks: q.("SELECT * FROM sync_acks"),
      cursors: q.("SELECT * FROM sync_cursors"),
      halts:
        Enum.filter(
          Enum.map(EventstoreSqlite.read_stream_forward("$sync", count: nil), & &1.data),
          &match?(%EventstoreSqlite.SystemEvents.SyncHalted{}, &1)
        )
    }
  end

  def stream_dump(stream) do
    q = &SQL.query!(EventstoreSqlite.RepoRead, &1, [stream]).rows

    %{
      live: q.("SELECT stream_version, event_id FROM stream_events WHERE stream_id = ?1 ORDER BY stream_version"),
      archived:
        q.("""
        SELECT a.id, e.stream_version, e.event_id FROM archived_streams a
        JOIN archived_stream_events e ON e.archive_id = a.id WHERE a.stream_id = ?1 ORDER BY a.id, e.stream_version
        """)
    }
  end

  def kill_replicator(peer) do
    case Registry.lookup(EventstoreSqlite.Sync.Registry, peer) do
      [{pid, _}] -> Process.exit(pid, :kill)
      [] -> false
    end
  end

  def received(pid) do
    send(pid, {:received, self()})

    receive do
      {:received, received} -> received
    after
      5_000 -> :timeout
    end
  end
end
