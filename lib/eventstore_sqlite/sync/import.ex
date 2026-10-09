defmodule EventstoreSqlite.Sync.Import do
  @moduledoc false

  alias Ecto.Adapters.SQL
  alias EventstoreSqlite.Changes
  alias EventstoreSqlite.RepoWrite
  alias EventstoreSqlite.Store
  alias EventstoreSqlite.Subscriptions
  alias EventstoreSqlite.Sync.Failpoint
  alias EventstoreSqlite.Sync.Selector
  alias EventstoreSqlite.Sync.State
  alias EventstoreSqlite.SystemEvents.NodeDiverged
  alias EventstoreSqlite.SystemEvents.NodeRetired
  alias EventstoreSqlite.SystemEvents.OwnershipAssigned
  alias EventstoreSqlite.SystemEvents.OwnershipReleased
  alias EventstoreSqlite.SystemEvents.OwnershipRevoked
  alias EventstoreSqlite.SystemEvents.ReleaseIgnored

  require Logger

  @transaction_events 1_000

  @doc """
  Applies a batch of entries exported by `origin`, in order.

  `origin_status` is `%{head: seq, diverged: boolean}` from the same export; it
  is stored with the cursor, so the home node can tell when a retired peer is
  drained.

  Returns:

    * `{:ok, %{cursor: seq, quarantined: n}}`;
    * `{:diverged, %{cursor: seq}}` — this node imported its own revocation;
    * `{:halt, reason, %{cursor: seq}}` — an entry can't be applied; entries
      before it were applied and committed;
    * `{:fenced, reason}` — replication from `origin` is halted, this node is
      diverged, or sync is disabled; nothing was applied.
  """
  def import_entries(origin, [], origin_status) do
    case fenced(EventstoreSqlite.RepoRead, origin) do
      {:ok, _state} ->
        if stored_status(EventstoreSqlite.RepoRead, origin) != {origin_status.head, origin_status.diverged} do
          RepoWrite.transact(
            fn repo ->
              set_cursor(repo, origin, cursor(repo, origin), origin_status)
              {:ok, :done}
            end,
            mode: :immediate
          )

          Changes.notify(:sync)
        end

        {:ok, %{cursor: cursor(EventstoreSqlite.RepoRead, origin), quarantined: 0}}

      {:error, {:fenced, reason}} ->
        {:fenced, reason}
    end
  end

  def import_entries(origin, entries, origin_status) do
    entries
    |> group()
    |> Enum.reduce_while({:ok, %{cursor: nil, quarantined: 0}}, fn group, {:ok, acc} ->
      case import_group(origin, group, origin_status) do
        {:ok, result} ->
          {:cont, {:ok, %{cursor: result.cursor, quarantined: acc.quarantined + result.quarantined}}}

        {:diverged, result} ->
          {:halt, {:diverged, result}}

        {:halt, reason, result} ->
          {:halt, {:halt, reason, %{cursor: result.cursor || acc.cursor}}}

        {:fenced, reason} ->
          {:halt, if(acc.cursor, do: {:ok, acc}, else: {:fenced, reason})}
      end
    end)
    |> tap(fn
      {:halt, reason, _} -> EventstoreSqlite.Sync.halt(origin, reason)
      _ -> :ok
    end)
  end

  defp group(entries) do
    {groups, current, _count} =
      Enum.reduce(entries, {[], [], 0}, fn
        %{kind: :archive} = entry, {groups, current, _count} ->
          {[[entry] | flush(groups, current)], [], 0}

        entry, {groups, current, count} ->
          size = length(entry.events)

          if current != [] and count + size > @transaction_events do
            {flush(groups, current), [entry], size}
          else
            {groups, [entry | current], count + size}
          end
      end)

    groups |> flush(current) |> Enum.reverse()
  end

  defp flush(groups, []), do: groups
  defp flush(groups, current), do: [Enum.reverse(current) | groups]

  defp import_group(origin, [%{kind: :archive} = entry], origin_status) do
    apply = fn ->
      RepoWrite.transact(fn repo -> archive_in_transaction(repo, origin, entry, origin_status) end, mode: :immediate)
    end

    case Subscriptions.apply_archive(entry.stream_id, apply) do
      {:ok, outcome} when outcome in [:applied, :duplicate, :quarantined] ->
        after_commit([entry.stream_id])
        {:ok, %{cursor: entry.seq, quarantined: if(outcome == :quarantined, do: 1, else: 0)}}

      {:error, {:fenced, reason}} ->
        {:fenced, reason}

      {:error, {:halt, reason}} ->
        {:halt, reason, %{cursor: nil}}
    end
  end

  defp import_group(origin, entries, origin_status) do
    result =
      RepoWrite.transact(
        fn repo ->
          with {:ok, state} <- fenced(repo, origin) do
            context = %{
              repo: repo,
              origin: origin,
              state: state,
              cursor: cursor(repo, origin),
              touched: MapSet.new(),
              quarantined: 0,
              halt: nil,
              diverged: false
            }

            context = Enum.reduce_while(entries, context, &apply_entry/2)
            State.save(repo, context.state)
            set_cursor(repo, origin, context.cursor, origin_status)
            Failpoint.hit(:import_before_commit)
            {:ok, context}
          end
        end,
        mode: :immediate
      )

    case result do
      {:ok, context} ->
        Failpoint.hit(:import_after_commit)
        after_commit(MapSet.to_list(context.touched))

        cond do
          context.diverged -> {:diverged, %{cursor: context.cursor}}
          context.halt -> {:halt, context.halt, %{cursor: context.cursor}}
          true -> {:ok, %{cursor: context.cursor, quarantined: context.quarantined}}
        end

      {:error, {:fenced, reason}} ->
        {:fenced, reason}
    end
  end

  defp fenced(repo, origin) do
    state = State.load(repo)

    cond do
      state.diverged -> {:error, {:fenced, :diverged}}
      not state.enabled -> {:error, {:fenced, :sync_disabled}}
      Map.has_key?(state.halted, origin) -> {:error, {:fenced, {:halted, state.halted[origin]}}}
      true -> {:ok, state}
    end
  end

  defp apply_entry(entry, context) do
    cond do
      entry.seq <= context.cursor ->
        {:cont, context}

      entry.seq > context.cursor + 1 ->
        {:halt, %{context | halt: {:gap, context.cursor, entry.seq}}}

      true ->
        case apply_new_entry(entry, context) do
          {:ok, context} -> continue(%{context | cursor: entry.seq})
          {:halt, reason} -> {:halt, %{context | halt: reason}}
        end
    end
  end

  defp continue(%{diverged: true} = context), do: {:halt, context}
  defp continue(context), do: {:cont, context}

  defp apply_new_entry(%{kind: :append} = entry, context) do
    case authorize(context.state, context.origin, entry) do
      :apply -> import_append(entry, context)
      :quarantine -> {:ok, quarantine(context, entry, :revoked_generation)}
      {:halt, reason} -> {:halt, reason}
    end
  end

  defp apply_new_entry(%{kind: :ownership, payload: payload} = entry, context) do
    apply_ownership(payload, entry, context)
  end

  defp import_append(entry, context) do
    local_version = Store.stream_version(context.repo, entry.stream_id)

    if local_version == entry.stream_version do
      :ok = Store.insert_raw_events(context.repo, entry.events)
      {:ok, _} = Store.append_to_stream_and_all(context.repo, entry.stream_id, Enum.map(entry.events, & &1.id))
      {:ok, %{context | touched: MapSet.put(context.touched, entry.stream_id)}}
    else
      {:halt, {:version_conflict, entry.stream_id, local_version, entry.stream_version}}
    end
  end

  defp apply_ownership({:assigned, selector, to}, entry, context) do
    if context.origin == context.state.home do
      {:ok, record(context, %OwnershipAssigned{selector: selector, to: to, generation: entry.seq})}
    else
      {:halt, {:ownership_violation, :assign_from_non_home, entry.seq}}
    end
  end

  defp apply_ownership({:released, generation}, entry, context) do
    %{state: state, origin: origin} = context

    cond do
      match?(%{owner: ^origin}, state.owners[generation]) ->
        {:ok, record(context, %OwnershipReleased{generation: generation, from: origin, release_seq: entry.seq})}

      match?(%{from: ^origin}, state.revoked[generation]) or Map.has_key?(state.released, generation) ->
        {:ok, record(context, %ReleaseIgnored{generation: generation, from: origin})}

      true ->
        {:halt, {:ownership_violation, {:release_of_unowned_generation, generation}, entry.seq}}
    end
  end

  defp apply_ownership({:node_revoked, node_id, revoked, cutoff}, entry, context) do
    if context.origin == context.state.home do
      context =
        Enum.reduce(revoked, context, fn {generation, selector}, context ->
          record(context, %OwnershipRevoked{generation: generation, selector: selector, from: node_id, cutoff: cutoff})
        end)

      context = record(context, %NodeRetired{node_id: node_id, revoke_seq: entry.seq})

      if node_id == context.state.node_id do
        Logger.error("eventstore_sqlite sync: #{context.origin} revoked this node; it now refuses every write")

        :telemetry.execute([:eventstore_sqlite, :sync, :diverged], %{}, %{
          node_id: node_id,
          revoked_by: context.origin
        })

        context = record(context, %NodeDiverged{node_id: node_id, revoked_by: context.origin, revoke_seq: entry.seq})
        {:ok, %{context | diverged: true}}
      else
        {:ok, context}
      end
    else
      {:halt, {:ownership_violation, :revoke_from_non_home, entry.seq}}
    end
  end

  defp record(context, event), do: %{context | state: State.record(context.repo, context.state, event)}

  @doc """
  Whether an append or archive entry from `origin` may be applied, must be
  quarantined, or breaks the single-writer rule.
  """
  def authorize(%State{} = state, origin, %{stream_id: stream_id, generation: generation}) do
    owners = state.owners
    revoked = state.revoked

    cond do
      generation > 0 and match?(%{owner: ^origin}, owners[generation]) and
          Selector.matches?(owners[generation].selector, stream_id) ->
        :apply

      generation == 0 and origin == state.home and State.owner(state, stream_id) == {state.home, 0} ->
        :apply

      match?(%{from: ^origin}, revoked[generation]) and Selector.matches?(revoked[generation].selector, stream_id) ->
        :quarantine

      true ->
        {:halt, {:ownership_violation, {:not_owner, stream_id, generation}}}
    end
  end

  defp quarantine(context, entry, reason) do
    SQL.query!(
      context.repo,
      """
      INSERT INTO sync_quarantine (origin, seq, entry, reason, inserted_at)
      VALUES (?1, ?2, ?3, ?4, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
      """,
      [context.origin, entry.seq, {:blob, :erlang.term_to_binary(entry)}, Atom.to_string(reason)]
    )

    :telemetry.execute([:eventstore_sqlite, :sync, :quarantine], %{count: 1}, %{origin: context.origin, seq: entry.seq})
    %{context | quarantined: context.quarantined + 1}
  end

  defp archive_in_transaction(repo, origin, entry, origin_status) do
    with {:ok, state} <- fenced(repo, origin) do
      cursor = cursor(repo, origin)

      cond do
        entry.seq <= cursor ->
          {:ok, :duplicate}

        entry.seq > cursor + 1 ->
          {:error, {:halt, {:gap, cursor, entry.seq}}}

        true ->
          outcome =
            case authorize(state, origin, entry) do
              :apply ->
                case Store.archive_in_transaction(repo, entry.stream_id, {:version, entry.stream_version}) do
                  {:ok, _count} -> {:ok, :applied}
                  {:error, reason} -> {:error, {:halt, {:archive_conflict, entry.stream_id, reason}}}
                end

              :quarantine ->
                quarantine(%{repo: repo, origin: origin, quarantined: 0}, entry, :revoked_generation)
                {:ok, :quarantined}

              {:halt, reason} ->
                {:error, {:halt, reason}}
            end

          with {:ok, _} <- outcome do
            set_cursor(repo, origin, entry.seq, origin_status)
            Failpoint.hit(:archive_before_commit)
            outcome
          end
      end
    end
  end

  defp after_commit(streams) do
    Enum.each(streams, &Subscriptions.ping/1)
    Enum.each(["$all", State.sync_stream(), State.ownership_stream()], &Subscriptions.ping/1)
    Changes.notify([:streams, :sync])
  end

  def cursor(repo, origin) do
    case SQL.query!(repo, "SELECT seq FROM sync_cursors WHERE origin = ?1", [origin]) do
      %{rows: [[seq]]} -> seq
      %{rows: []} -> 0
    end
  end

  defp set_cursor(repo, origin, seq, origin_status) do
    SQL.query!(
      repo,
      """
      INSERT INTO sync_cursors (origin, seq, origin_head, origin_diverged, applied_at)
      VALUES (?1, ?2, ?3, ?4, CASE WHEN ?2 > 0 THEN strftime('%Y-%m-%dT%H:%M:%SZ', 'now') END)
      ON CONFLICT (origin) DO UPDATE
        SET seq = excluded.seq,
            origin_head = excluded.origin_head,
            origin_diverged = excluded.origin_diverged,
            applied_at = CASE WHEN excluded.seq > sync_cursors.seq THEN excluded.applied_at ELSE sync_cursors.applied_at END
      """,
      [origin, seq, origin_status.head, if(origin_status.diverged, do: 1, else: 0)]
    )
  end

  defp stored_status(repo, origin) do
    case SQL.query!(repo, "SELECT origin_head, origin_diverged FROM sync_cursors WHERE origin = ?1", [origin]) do
      %{rows: [[head, diverged]]} -> {head, diverged == 1}
      %{rows: []} -> nil
    end
  end
end
