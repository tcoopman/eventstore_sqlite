defmodule EventstoreSqlite.Sync.Failpoint do
  @moduledoc false

  if Application.compile_env(:eventstore_sqlite, :failpoints, false) do
    @doc """
    Acts on the failpoint `name` when a test has set one: `{:raise, message}`,
    `{:exit, reason}`, `:halt` (the node dies at once), or `{:block, pid}`
    (sends `{:failpoint, name, self()}` to `pid` and waits for
    `{:failpoint_continue, name}`). `{:once, action}` acts once.
    """
    def hit(name) do
      case :persistent_term.get({__MODULE__, name}, nil) do
        nil ->
          :ok

        {:once, action} ->
          clear(name)
          act(name, action)

        action ->
          act(name, action)
      end
    end

    defp act(_name, {:raise, message}), do: raise(message)
    defp act(_name, {:exit, reason}), do: exit(reason)
    defp act(_name, :halt), do: :erlang.halt(137, flush: false)

    defp act(name, {:block, pid}) do
      send(pid, {:failpoint, name, self()})

      receive do
        {:failpoint_continue, ^name} -> :ok
      end
    end

    def set(name, action), do: :persistent_term.put({__MODULE__, name}, action)

    def clear(name) do
      :persistent_term.erase({__MODULE__, name})
      :ok
    end

    def clear_all do
      for {{__MODULE__, _} = key, _} <- :persistent_term.get(), do: :persistent_term.erase(key)
      :ok
    end
  else
    def hit(_name), do: :ok
  end
end
