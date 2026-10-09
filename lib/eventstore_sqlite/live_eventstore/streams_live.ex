if Code.ensure_loaded?(Phoenix.LiveView) and Code.ensure_loaded?(Fluxon) do
  defmodule EventstoreSqlite.LiveEventstore.StreamsLive do
    @moduledoc false
    use Phoenix.LiveView
    use Fluxon, only: [:badge, :checkbox, :input, :table]

    import EventstoreSqlite.LiveEventstore.Helpers
    import EventstoreSqlite.LiveEventstore.Layouts, only: [page: 1, card: 1, section_title: 1, pager_button: 1]

    alias EventstoreSqlite.Ownership
    alias EventstoreSqlite.Sync

    @page_size 50
    @history_size 15
    @fallback_refresh 30_000

    @impl true
    def mount(_params, session, socket) do
      socket =
        assign(socket,
          base_path: session["base_path"],
          live_socket_path: session["live_socket_path"],
          page_title: "Streams · live_eventstore"
        )

      if connected?(socket) do
        subscribe()
        Process.send_after(self(), :fallback_refresh, @fallback_refresh)
      end

      {:ok, load_sync(socket)}
    end

    @impl true
    def handle_params(params, _uri, socket) do
      filters = %{
        search: params |> Map.get("search", "") |> String.trim(),
        system: params["system"] == "true",
        after: params["after"]
      }

      {:noreply, socket |> assign(filters: filters) |> load_streams()}
    end

    @impl true
    def handle_event("filter", params, socket) do
      filters = %{
        socket.assigns.filters
        | search: params["search"] || "",
          system: params["system"] == "true",
          after: nil
      }

      {:noreply, push_patch(socket, to: streams_path(socket.assigns.base_path, filters))}
    end

    @impl true
    def handle_info({:eventstore_sqlite, :changed, kinds}, socket) do
      socket = if :streams in kinds, do: load_streams(socket), else: socket
      socket = if :sync in kinds, do: load_sync(socket), else: socket
      {:noreply, socket}
    end

    def handle_info(:fallback_refresh, socket) do
      Process.send_after(self(), :fallback_refresh, @fallback_refresh)
      {:noreply, socket |> load_streams() |> load_sync()}
    end

    def handle_info({:DOWN, _ref, :process, _pid, _reason}, socket) do
      schedule_resubscribe()
      {:noreply, socket}
    end

    def handle_info(:resubscribe, socket) do
      resubscribe()
      {:noreply, socket |> load_streams() |> load_sync()}
    end

    defp load_streams(socket) do
      filters = socket.assigns.filters

      page =
        EventstoreSqlite.list_stream_infos(
          search: filters.search,
          system: filters.system,
          after: filters.after,
          limit: @page_size
        )

      assign(socket, page: page)
    end

    defp load_sync(socket) do
      status = Sync.status()

      if status.enabled do
        assign(socket, sync: status, assignments: Ownership.list(), history: history())
      else
        assign(socket, sync: status, assignments: [], history: [])
      end
    end

    defp history do
      ["$sync", "$ownership"]
      |> Enum.flat_map(&EventstoreSqlite.read_stream_backward(&1, count: @history_size))
      |> Enum.sort_by(&{&1.created_at, &1.id}, &>=/2)
      |> Enum.take(@history_size)
    end

    defp streams_path(base_path, filters) do
      path(base_path, "", search: filters.search, system: filters.system && "true", after: filters.after)
    end

    defp peer_color(state) when state in [:connected, :drained], do: "success"
    defp peer_color(state) when state in [:disconnected, :busy], do: "warning"
    defp peer_color(_state), do: "danger"

    defp event_name(%{data: %type{}}), do: type |> Module.split() |> List.last()

    defp event_fields(%{data: data}) do
      data
      |> Map.from_struct()
      |> Enum.map_join(", ", fn {key, value} -> "#{key}: #{inspect(value)}" end)
    end

    @impl true
    def render(assigns) do
      ~H"""
      <.page base_path={@base_path} sync={@sync}>
        <section :if={@sync.enabled} id="sync" class="space-y-6">
          <div class="grid grid-cols-1 gap-4 sm:grid-cols-3">
            <.card label="Change log" id="log-entries">
              {plural(@sync.log.entries, "entry")}
              <:sub>retained for peers · head {number(@sync.head)}</:sub>
            </.card>
            <.card label="Peers">
              {map_size(@sync.peers)}
              <:sub>{plural(length(@assignments), "assignment")}</:sub>
            </.card>
            <.card :if={@sync.diverged} label="Diverged">
              revoked by {@sync.diverged.revoked_by}
              <:sub>this node refuses every write</:sub>
            </.card>
          </div>

          <div>
            <.section_title title="Peers" />
            <div class="surface rounded-base overflow-x-auto">
              <.table id="peers">
                <.table_head>
                  <:col>Peer</:col>
                  <:col>State</:col>
                  <:col class="text-right">Lag</:col>
                  <:col>Last applied</:col>
                  <:col>Last success</:col>
                  <:col class="text-right">Acked</:col>
                  <:col class="text-right">Quarantined</:col>
                  <:col>Owns</:col>
                  <:col>Problem</:col>
                </.table_head>
                <.table_body>
                  <.table_row :for={{peer, status} <- Enum.sort(@sync.peers)}>
                    <:cell class="font-mono">{peer}</:cell>
                    <:cell><.badge size="sm" color={peer_color(status.state)}>{status.state}</.badge></:cell>
                    <:cell class="text-right tabular-nums">{number(status.lag)}</:cell>
                    <:cell class="text-foreground-softer tabular-nums">{time(status.last_applied_at)}</:cell>
                    <:cell class="text-foreground-softer tabular-nums">{time(status.last_success)}</:cell>
                    <:cell class="text-right tabular-nums">{number(status.acked)}</:cell>
                    <:cell class="text-right tabular-nums">{number(status.quarantined)}</:cell>
                    <:cell>{Enum.map_join(status.owns, ", ", &"gen #{&1}")}</:cell>
                    <:cell class="text-danger text-xs">
                      <span :if={status.halted}>halted: {inspect(status.halted)}</span>
                      <span :if={!status.halted && status.last_error}>{inspect(status.last_error)}</span>
                    </:cell>
                  </.table_row>
                </.table_body>
              </.table>
              <div :if={@sync.peers == %{}} class="text-foreground-softer p-6 text-center">No peers.</div>
            </div>
          </div>

          <div :if={@assignments != []}>
            <.section_title title="Assignments" />
            <div class="surface rounded-base overflow-x-auto">
              <.table id="assignments">
                <.table_head>
                  <:col class="text-right">Generation</:col>
                  <:col>Streams</:col>
                  <:col>Owner</:col>
                </.table_head>
                <.table_body>
                  <.table_row :for={assignment <- @assignments}>
                    <:cell class="text-right tabular-nums">{assignment.generation}</:cell>
                    <:cell class="font-mono">{assignment.selector}</:cell>
                    <:cell>{assignment.owner}</:cell>
                  </.table_row>
                </.table_body>
              </.table>
            </div>
          </div>
        </section>

        <section>
          <.section_title title="Streams" />
          <form id="filter" class="mb-3 flex flex-wrap items-center gap-4" phx-change="filter" phx-submit="filter">
            <div class="min-w-64 flex-1">
              <.input
                type="search"
                name="search"
                value={@filters.search}
                placeholder="Filter streams by name"
                phx-debounce="250"
                autocomplete="off"
              />
            </div>
            <.checkbox name="system" value="true" checked={@filters.system} label="System streams" />
          </form>

          <div class="surface rounded-base overflow-x-auto">
            <.table id="streams">
              <.table_head>
                <:col>Stream</:col>
                <:col class="text-right">Version</:col>
                <:col>Created</:col>
                <:col>Last event</:col>
                <:col :if={@sync.enabled}>Owner</:col>
              </.table_head>
              <.table_body>
                <.table_row :for={stream <- @page.entries}>
                  <:cell class="font-mono">
                    <span class={if(system_stream?(stream.stream_id), do: "text-foreground-softer", else: "text-foreground")}>{stream.stream_id}</span>
                  </:cell>
                  <:cell class="text-right tabular-nums">{number(stream.version)}</:cell>
                  <:cell class="text-foreground-softer tabular-nums">{time(stream.created_at)}</:cell>
                  <:cell class="text-foreground-softer tabular-nums">{time(stream.last_event_at)}</:cell>
                  <:cell :if={@sync.enabled}>{owner(stream.owner)}</:cell>
                </.table_row>
              </.table_body>
            </.table>
            <div :if={@page.entries == []} class="text-foreground-softer p-6 text-center">No streams match.</div>
          </div>

          <nav :if={@filters.after || @page.next} class="pager mt-3 flex justify-end gap-2">
            <.pager_button patch={@filters.after && streams_path(@base_path, %{@filters | after: nil})}>
              ← First page
            </.pager_button>
            <.pager_button patch={@page.next && streams_path(@base_path, %{@filters | after: @page.next})}>
              Next →
            </.pager_button>
          </nav>
        </section>

        <section :if={@history != []} id="history">
          <.section_title title="Sync history" />
          <div class="surface rounded-base overflow-x-auto">
            <.table>
              <.table_body>
                <.table_row :for={event <- @history}>
                  <:cell class="text-foreground-softer whitespace-nowrap tabular-nums">{time(event.created_at)}</:cell>
                  <:cell class="font-medium">{event_name(event)}</:cell>
                  <:cell class="text-foreground-softer break-all font-mono text-xs">{event_fields(event)}</:cell>
                </.table_row>
              </.table_body>
            </.table>
          </div>
        </section>
      </.page>
      """
    end
  end
end
