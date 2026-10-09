if Code.ensure_loaded?(Phoenix.LiveView) and Code.ensure_loaded?(Fluxon) do
  defmodule EventstoreSqlite.LiveEventstore.Helpers do
    @moduledoc false

    @resubscribe_after 100

    @doc """
    Subscribes the calling LiveView to store changes, monitoring the process
    that holds the subscription. On its `:DOWN`, call `schedule_resubscribe/0`,
    and `resubscribe/0` when `:resubscribe` arrives.
    """
    def subscribe do
      Process.monitor(EventstoreSqlite.Changes)
      :ok = EventstoreSqlite.subscribe_to_changes(self())
    end

    def schedule_resubscribe, do: Process.send_after(self(), :resubscribe, @resubscribe_after)

    @doc """
    Subscribes again after the changes process went down, and tries again later
    while its supervisor hasn't restarted it yet.
    """
    def resubscribe do
      subscribe()
    catch
      :exit, _not_restarted_yet -> schedule_resubscribe()
    end

    def path(base_path, suffix, query) do
      query = Enum.reject(query, fn {_key, value} -> value in [nil, "", false] end)
      root = if base_path == "" and suffix == "", do: "/", else: base_path <> suffix
      if query == [], do: root, else: root <> "?" <> URI.encode_query(query)
    end

    def root_path(""), do: "/"
    def root_path(base_path), do: base_path

    def number(nil), do: "—"

    def number(integer) do
      integer
      |> Integer.to_string()
      |> String.reverse()
      |> String.replace(~r/(\d{3})(?=\d)/, "\\1 ")
      |> String.reverse()
    end

    def time(nil), do: "—"
    def time(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S")

    def owner(nil), do: ""
    def owner({node_id, 0}), do: node_id
    def owner({node_id, generation}), do: "#{node_id} · gen #{generation}"

    def plural(1, word), do: "1 #{word}"
    def plural(count, word), do: "#{number(count)} #{word}s"

    def system_stream?(stream_id), do: stream_id in EventstoreSqlite.system_streams()
  end
end
