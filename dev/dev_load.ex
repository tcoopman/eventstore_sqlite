defmodule EventstoreSqlite.Sync.DevLoad.Event do
  @moduledoc false
  defstruct [:text, :at]
end

defmodule EventstoreSqlite.Sync.DevLoad do
  @moduledoc """
  Generates write load for manual sync tests. Only compiled in dev.

      DevLoad.start(["orders:*"], 200)   # 200 single-event appends a second
      DevLoad.stats()
      DevLoad.stop()

  A selector `"orders:*"` writes to `"orders:1"` .. `"orders:20"`; an exact
  name writes to that stream. Several loads can run at once.
  """
  use GenServer

  @scope EventstoreSqlite.Sync.PG
  @group :eventstore_sqlite_dev_load
  @tick 50

  def start(selectors, rate) when is_list(selectors) and rate > 0 do
    GenServer.start(__MODULE__, {selectors, rate})
  end

  def stop do
    for pid <- :pg.get_local_members(@scope, @group), do: GenServer.stop(pid)
    :ok
  end

  def stats do
    @scope
    |> :pg.get_local_members(@group)
    |> Enum.map(&GenServer.call(&1, :stats))
    |> Enum.reduce(%{ok: 0, not_owner: 0, errors: %{}}, fn stats, acc ->
      %{
        ok: acc.ok + stats.ok,
        not_owner: acc.not_owner + stats.not_owner,
        errors: Map.merge(acc.errors, stats.errors, fn _, a, b -> a + b end)
      }
    end)
  end

  @impl true
  def init({selectors, rate}) do
    :ok = :pg.join(@scope, @group, self())
    :timer.send_interval(@tick, :tick)
    streams = Enum.flat_map(selectors, &streams/1)
    {:ok, %{streams: streams, per_tick: max(div(rate * @tick, 1_000), 1), ok: 0, not_owner: 0, errors: %{}, n: 0}}
  end

  defp streams(selector) do
    if String.ends_with?(selector, "*") do
      prefix = String.trim_trailing(selector, "*")
      Enum.map(1..20, &"#{prefix}#{&1}")
    else
      [selector]
    end
  end

  @impl true
  def handle_info(:tick, state), do: {:noreply, Enum.reduce(1..state.per_tick, state, fn _, state -> append(state) end)}

  @impl true
  def handle_call(:stats, _from, state), do: {:reply, Map.take(state, [:ok, :not_owner, :errors]), state}

  defp append(state) do
    stream = Enum.random(state.streams)
    event = %EventstoreSqlite.Sync.DevLoad.Event{text: "#{node()} #{state.n}", at: DateTime.utc_now()}

    case EventstoreSqlite.append_to_stream(stream, [event]) do
      :ok -> %{state | ok: state.ok + 1, n: state.n + 1}
      {:error, :not_owner} -> %{state | not_owner: state.not_owner + 1}
      {:error, reason} -> %{state | errors: Map.update(state.errors, reason, 1, &(&1 + 1))}
    end
  end
end
