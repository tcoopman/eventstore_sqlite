defmodule EventstoreSqlite.Sync.Write do
  @moduledoc false

  alias EventstoreSqlite.Sync.Log
  alias EventstoreSqlite.Sync.State

  @pg EventstoreSqlite.Sync.PG

  def pg_scope, do: @pg

  @doc """
  Decides inside a write transaction whether this node may write `stream_id`.
  Divergence is checked first, so nothing can bypass it.
  """
  def authorize(repo, stream_id) do
    state = State.load(repo)

    cond do
      state.diverged ->
        {:error, :diverged}

      not state.enabled ->
        {:ok, :disabled}

      true ->
        case State.owner(state, stream_id) do
          {owner, generation} when owner == state.node_id -> {:ok, %{node_id: state.node_id, generation: generation}}
          _ -> {:error, :not_owner}
        end
    end
  end

  def log_append(_repo, :disabled, _stream_id, _first_version, _event_ids), do: :ok

  def log_append(repo, sync, stream_id, first_version, event_ids) do
    Log.append(repo, :append, %{
      stream_id: stream_id,
      stream_version: first_version,
      generation: sync.generation,
      event_ids: event_ids
    })

    :ok
  end

  def log_archive(_repo, :disabled, _stream_id, _event_count), do: :ok

  def log_archive(repo, sync, stream_id, event_count) do
    Log.append(repo, :archive, %{stream_id: stream_id, stream_version: event_count, generation: sync.generation})
    :ok
  end

  def notify(:disabled), do: :ok
  def notify(%{node_id: node_id}), do: poke(node_id)

  @doc """
  Tells the replicators pulling from `node_id` that its log grew. Only a hint:
  replicators also pull on a timer.
  """
  def poke(node_id) do
    for pid <- :pg.get_members(@pg, {:replicator, node_id}), do: send(pid, :sync_poke)
    :ok
  end
end
