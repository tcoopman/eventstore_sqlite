defmodule EventstoreSqlite.Ownership do
  @moduledoc """
  Which node may write which streams, once sync is enabled
  (`EventstoreSqlite.Sync`).

  The home node owns every stream unless it assigns a selector to another
  node. A selector is an exact stream name or a prefix ending in `*`
  (`"venue:*"`). Assignments can't overlap: `"venue:*"` and `"venue:vip"`
  can't both be assigned. Each assignment has a **generation**, a number the
  home node hands out; it identifies that assignment for its whole life.

  A node that doesn't own a stream gets `{:error, :not_owner}` from
  `EventstoreSqlite.append_to_stream/3` and `EventstoreSqlite.archive_stream/2`.

  Handing streams back to the home node:

    * `reclaim/2` — the planned way: the owner stops writing, and the home node
      takes over once it has every event the owner wrote. Nothing is lost.
    * `revoke_node/1` — when the owner is unreachable: the home node takes over
      at once. Entries the owner wrote that the home node hadn't pulled yet are
      quarantined (`EventstoreSqlite.Sync.quarantine/0`). The owner becomes
      diverged when it hears of it, refuses every write from then on, and has
      to be rebuilt from a new snapshot under a new node id.
  """

  alias EventstoreSqlite.RepoRead
  alias EventstoreSqlite.Sync
  alias EventstoreSqlite.Sync.Failpoint
  alias EventstoreSqlite.Sync.Import
  alias EventstoreSqlite.Sync.Log
  alias EventstoreSqlite.Sync.Replicator
  alias EventstoreSqlite.Sync.Selector
  alias EventstoreSqlite.Sync.State
  alias EventstoreSqlite.Sync.Write
  alias EventstoreSqlite.SystemEvents.NodeRetired
  alias EventstoreSqlite.SystemEvents.OwnershipAssigned
  alias EventstoreSqlite.SystemEvents.OwnershipReleased
  alias EventstoreSqlite.SystemEvents.OwnershipRevoked

  @doc """
  Assigns the streams matching `selector` to the peer `to`, on the home node.
  Returns `{:ok, generation}`.

  The home node refuses writes to those streams from the moment this returns.
  The peer may write them as soon as it has pulled the assignment; by then it
  has every event the home node wrote to them.

  Returns `{:error, reason}` with `reason` one of `:overlap` (another
  assignment overlaps `selector`), `:unknown_peer`, `:retired`, `:home`,
  `:not_home`, `:sync_disabled` or `:diverged`. Raises `ArgumentError` for an
  invalid selector.
  """
  def assign(selector, to) when is_binary(to) do
    Selector.parse!(selector)

    result =
      Sync.transact_state(fn repo, state ->
        with :ok <- Sync.guard_home(state) do
          cond do
            to == state.node_id ->
              {:error, :home}

            Map.has_key?(state.retired, to) ->
              {:error, :retired}

            not Map.has_key?(state.peers, to) ->
              {:error, :unknown_peer}

            Enum.any?(state.owners, fn {_, owner} -> Selector.overlap?(owner.selector, selector) end) ->
              {:error, :overlap}

            true ->
              record_assignment(repo, state, selector, to)
          end
        end
      end)

    Failpoint.hit(:ownership_after_commit)
    result
  end

  defp record_assignment(repo, state, selector, to) do
    generation = Log.append(repo, :ownership, %{payload: {:assigned, selector, to}})
    state = State.record(repo, state, %OwnershipAssigned{selector: selector, to: to, generation: generation})
    {:ok, state, {:ok, generation}}
  end

  @doc """
  Hands the assignment `generation` back to the home node, on the node that
  owns it. From the moment this returns, the node refuses writes to those
  streams. The home node takes them over once it has pulled the release.

  Returns `{:ok, release_seq}`, also when the generation was already released
  by this node, so it can be retried. Returns `{:error, :not_active}` when this
  node doesn't own `generation`.

  Usually called by `reclaim/2` from the home node.
  """
  def release(generation) when is_integer(generation) do
    result =
      Sync.transact_state(fn repo, state ->
        node_id = state.node_id

        cond do
          state.diverged ->
            {:error, :diverged}

          not state.enabled ->
            {:error, :sync_disabled}

          match?(%{owner: ^node_id}, state.released[generation]) ->
            {:ok, state, {:ok, state.released[generation].release_seq}}

          match?(%{owner: ^node_id}, state.owners[generation]) ->
            record_release(repo, state, generation)

          true ->
            {:error, :not_active}
        end
      end)

    Failpoint.hit(:release_after_commit)
    result
  end

  defp record_release(repo, state, generation) do
    seq = Log.append(repo, :ownership, %{payload: {:released, generation}})
    state = State.record(repo, state, %OwnershipReleased{generation: generation, from: state.node_id, release_seq: seq})
    {:ok, state, {:ok, seq}}
  end

  @doc """
  Takes the assignment `generation` back, on the home node: asks its owner to
  release it, then waits until this node has pulled the release.

  Takes a generation rather than a selector, so a retry can never touch a later
  assignment of the same streams. Returns `:ok` (also when `generation` was
  already released), or `{:error, reason}` with `reason` one of `:timeout`,
  `:unreachable`, `:revoked`, `:not_active`, `{:owner, error}`, `:not_home`,
  `:sync_disabled` or `:diverged`.

  Options: `:timeout`, how long to wait in milliseconds for the release to be
  pulled (default 30 000). The request to the owner itself may take up to
  5 seconds more.
  """
  def reclaim(generation, opts \\ []) when is_integer(generation) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    state = State.load(RepoRead)

    with :ok <- Sync.guard_home(state) do
      cond do
        Map.has_key?(state.released, generation) -> :ok
        Map.has_key?(state.revoked, generation) -> {:error, :revoked}
        owner = state.owners[generation] -> request_release(owner.owner, generation, timeout)
        true -> {:error, :not_active}
      end
    end
  end

  defp request_release(owner, generation, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    case :pg.get_members(Write.pg_scope(), {:node, owner}) do
      [pid] ->
        case remote_release(node(pid), generation, max(timeout, 5_000)) do
          {:ok, _release_seq} ->
            Replicator.pull_now(owner)
            await_release(generation, deadline)

          {:error, :unreachable} ->
            {:error, :unreachable}

          {:error, reason} ->
            {:error, {:owner, reason}}
        end

      _ ->
        {:error, :unreachable}
    end
  end

  defp remote_release(node, generation, timeout) do
    :erpc.call(node, __MODULE__, :release, [generation], timeout)
  catch
    _kind, _reason -> {:error, :unreachable}
  end

  defp await_release(generation, deadline) do
    cond do
      Map.has_key?(State.load(RepoRead).released, generation) ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        {:error, :timeout}

      true ->
        Process.sleep(20)
        await_release(generation, deadline)
    end
  end

  @doc """
  Takes every stream `node_id` owns back at once, on the home node, without
  asking it: the forced reclaim, for an owner that is unreachable. `node_id` is
  retired: it can never own streams again.

  Entries `node_id` wrote under those assignments that this node hasn't pulled
  yet are quarantined when they arrive, instead of applied. When `node_id`
  hears of the revocation it becomes diverged: it refuses every write and has
  to be rebuilt from a new snapshot under a new node id. It also works for a
  node that owns nothing anymore.

  Returns `{:ok, revoked_generations}`, or `{:error, reason}` with `reason` one
  of `:unknown_peer`, `:retired`, `:home`, `:not_home`, `:sync_disabled` or
  `:diverged`.
  """
  def revoke_node(node_id) when is_binary(node_id) do
    result =
      Sync.transact_state(fn repo, state ->
        with :ok <- Sync.guard_home(state) do
          cond do
            node_id == state.node_id -> {:error, :home}
            Map.has_key?(state.retired, node_id) -> {:error, :retired}
            not Map.has_key?(state.peers, node_id) -> {:error, :unknown_peer}
            true -> record_revocation(repo, state, node_id)
          end
        end
      end)

    Failpoint.hit(:ownership_after_commit)
    result
  end

  defp record_revocation(repo, state, node_id) do
    revoked =
      state.owners
      |> Enum.filter(fn {_generation, owner} -> owner.owner == node_id end)
      |> Enum.map(fn {generation, owner} -> {generation, owner.selector} end)
      |> Enum.sort()

    cutoff = Import.cursor(repo, node_id)
    seq = Log.append(repo, :ownership, %{payload: {:node_revoked, node_id, revoked, cutoff}})

    state =
      Enum.reduce(revoked, state, fn {generation, selector}, state ->
        State.record(repo, state, %OwnershipRevoked{
          generation: generation,
          selector: selector,
          from: node_id,
          cutoff: cutoff
        })
      end)

    state = State.record(repo, state, %NodeRetired{node_id: node_id, revoke_seq: seq})
    {:ok, state, {:ok, Enum.map(revoked, &elem(&1, 0))}}
  end

  @doc """
  The node that may write `stream_id`, and the generation that allows it
  (`0` for the home node's default ownership). Returns
  `{:error, :sync_disabled}` when sync is off.
  """
  def owner(stream_id) when is_binary(stream_id) do
    state = State.load(RepoRead)
    if state.enabled, do: State.owner(state, stream_id), else: {:error, :sync_disabled}
  end

  @doc """
  The active assignments, as `%{generation, selector, owner}` maps ordered by
  generation.
  """
  def list do
    RepoRead
    |> State.load()
    |> Map.fetch!(:owners)
    |> Enum.sort()
    |> Enum.map(fn {generation, owner} -> %{generation: generation, selector: owner.selector, owner: owner.owner} end)
  end
end
