if Code.ensure_loaded?(Phoenix.LiveView) and Code.ensure_loaded?(Fluxon) do
  defmodule EventstoreSqlite.LiveEventstore.StreamLive do
    @moduledoc false
    use Phoenix.LiveView
    use Fluxon, only: [:badge, :button, :sheet, :table]

    import EventstoreSqlite.LiveEventstore.Helpers
    import EventstoreSqlite.LiveEventstore.Layouts, only: [page: 1, card: 1, section_title: 1, pager_button: 1]

    alias EventstoreSqlite.LiveEventstore.Payload
    alias EventstoreSqlite.Sync
    alias Phoenix.LiveView.JS

    @page_size 25
    @max_rendered_bytes 50_000
    @fallback_refresh 30_000

    @impl true
    def mount(_params, session, socket) do
      socket =
        assign(socket,
          base_path: session["base_path"],
          live_socket_path: session["live_socket_path"],
          sync: Sync.status()
        )

      if connected?(socket) do
        subscribe()
        Process.send_after(self(), :fallback_refresh, @fallback_refresh)
      end

      {:ok, socket}
    end

    @impl true
    def handle_params(%{"id" => stream_id} = params, _uri, socket) do
      socket =
        socket
        |> assign(
          stream_id: stream_id,
          before: version_param(params["before"]),
          selected_version: version_param(params["event"]),
          page_title: "#{stream_id} · live_eventstore"
        )
        |> load()

      {:noreply, socket}
    end

    def handle_params(_params, _uri, socket) do
      {:noreply, push_navigate(socket, to: root_path(socket.assigns.base_path))}
    end

    @impl true
    def handle_event("download", %{"version" => version}, socket) do
      stream_id = socket.assigns.stream_id

      socket =
        case read_event(stream_id, String.to_integer(version)) do
          nil ->
            socket

          event ->
            push_event(socket, "live_eventstore:download", %{
              filename: download_name(stream_id, event.stream_version),
              content: Payload.event_json(event)
            })
        end

      {:noreply, socket}
    end

    @impl true
    def handle_info({:eventstore_sqlite, :changed, kinds}, socket) do
      socket = if :streams in kinds, do: load(socket), else: socket
      socket = if :sync in kinds, do: assign(socket, sync: Sync.status()), else: socket
      {:noreply, socket}
    end

    def handle_info(:fallback_refresh, socket) do
      Process.send_after(self(), :fallback_refresh, @fallback_refresh)
      {:noreply, socket |> assign(sync: Sync.status()) |> load()}
    end

    def handle_info({:DOWN, _ref, :process, _pid, _reason}, socket) do
      schedule_resubscribe()
      {:noreply, socket}
    end

    def handle_info(:resubscribe, socket) do
      resubscribe()
      {:noreply, load(socket)}
    end

    defp load(socket) do
      case EventstoreSqlite.stream_info(socket.assigns.stream_id) do
        {:ok, info} ->
          before = min(socket.assigns.before || info.version, info.version)
          from = max(before - @page_size, 0)

          newer = before + @page_size

          assign(socket,
            info: info,
            from: from,
            to: before,
            latest?: before == info.version,
            newer_before: if(newer < info.version, do: newer),
            events: socket.assigns.stream_id |> read_window(from, before) |> Enum.map(&row/1),
            selected:
              socket.assigns.selected_version && selected(socket.assigns.stream_id, socket.assigns.selected_version)
          )

        {:error, :not_found} ->
          assign(socket, info: nil, events: [], from: 0, to: 0, latest?: true, newer_before: nil, selected: nil)
      end
    end

    defp read_window(_stream_id, from, before) when before <= from, do: []

    defp read_window(stream_id, from, before) do
      {stream_id, from}
      |> EventstoreSqlite.read_stream_forward(count: before - from)
      |> Enum.filter(&(&1.stream_version < before))
      |> Enum.reverse()
    end

    defp read_event(stream_id, version) do
      case EventstoreSqlite.read_stream_forward({stream_id, version}, count: 1) do
        [%{stream_version: ^version} = event] -> event
        _ -> nil
      end
    end

    defp row(event) do
      data_size = byte_size(Payload.data_json(event.data))

      %{
        event: event,
        data_size: data_size,
        large?: data_size > @max_rendered_bytes,
        metadata_keys: map_size(event.metadata)
      }
    end

    defp selected(stream_id, version) do
      case read_event(stream_id, version) do
        nil ->
          nil

        event ->
          %{event: event, metadata: rendered(Payload.json(event.metadata)), data: rendered(Payload.data_json(event.data))}
      end
    end

    defp rendered(json) when byte_size(json) > @max_rendered_bytes, do: {:too_big, byte_size(json)}
    defp rendered(json), do: {:ok, json}

    defp version_param(nil), do: nil

    defp version_param(value) do
      case Integer.parse(value) do
        {version, ""} when version >= 0 -> version
        _ -> nil
      end
    end

    defp download_name(stream_id, version) do
      String.replace(stream_id, ~r/[^A-Za-z0-9._-]+/, "_") <> "-#{version}.json"
    end

    defp page_path(assigns, overrides) do
      query = Keyword.merge([before: assigns.before, event: nil], overrides)
      stream_path(assigns.base_path, assigns.stream_id, before: query[:before], event: query[:event])
    end

    defp short_type(type), do: type |> String.split(".") |> List.last()

    defp original?(%{stream_id: stream_id, original_stream_id: original}), do: original && original != stream_id

    attr :label, :string, required: true
    slot :inner_block, required: true

    defp field(assigns) do
      ~H"""
      <div class="border-base flex gap-4 border-b py-2 last:border-b-0">
        <dt class="text-foreground-softer w-36 shrink-0">{@label}</dt>
        <dd class="min-w-0 break-all">{render_slot(@inner_block)}</dd>
      </div>
      """
    end

    attr :title, :string, required: true
    attr :id, :string, required: true
    attr :json, :any, required: true

    defp json_block(assigns) do
      ~H"""
      <div>
        <h3 class="text-foreground-softer mb-2 text-xs font-semibold uppercase tracking-wide">{@title}</h3>
        <%= case @json do %>
          <% {:ok, json} -> %>
            <pre id={@id} class="bg-sunken border-base rounded-base max-h-[50vh] overflow-auto border p-3 font-mono text-xs leading-relaxed">{json}</pre>
          <% {:too_big, size} -> %>
            <div id={@id} class="border-base rounded-base text-foreground-softer border border-dashed p-4">
              {bytes(size)} of JSON: too big to show here. Download the event to see it.
            </div>
        <% end %>
      </div>
      """
    end

    @impl true
    def render(assigns) do
      ~H"""
      <.page base_path={@base_path} sync={@sync}>
        <div>
          <.link navigate={root_path(@base_path)} class="text-foreground-softer hover:text-foreground text-sm">
            ← All streams
          </.link>
          <h1 id="stream-name" class="mt-2 break-all font-mono text-lg font-semibold">{@stream_id}</h1>
        </div>

        <%= if @info do %>
          <div class="grid grid-cols-2 gap-4 lg:grid-cols-4">
            <.card label="Version" id="stream-version">{number(@info.version)}</.card>
            <.card label="Created">{time(@info.created_at)}</.card>
            <.card label="Last event">{time(@info.last_event_at)}</.card>
            <.card :if={@info.owner} label="Owner">{owner(@info.owner)}</.card>
          </div>

          <section>
            <.section_title title={"Events #{number(@from)}–#{number(max(@to - 1, 0))}"}>
              <nav class="pager flex gap-2">
                <.pager_button patch={!@latest? && page_path(assigns, before: nil)}>Latest</.pager_button>
                <.pager_button patch={!@latest? && page_path(assigns, before: @newer_before)}>← Newer</.pager_button>
                <.pager_button patch={@from > 0 && page_path(assigns, before: @from)}>Older →</.pager_button>
              </nav>
            </.section_title>

            <div class="surface rounded-base overflow-x-auto">
              <.table id="events">
                <.table_head>
                  <:col class="text-right">Version</:col>
                  <:col>Type</:col>
                  <:col>Created</:col>
                  <:col :if={Enum.any?(@events, &original?(&1.event))}>Original stream</:col>
                  <:col class="text-right">Metadata</:col>
                  <:col class="text-right">Data</:col>
                  <:col></:col>
                </.table_head>
                <.table_body>
                  <.table_row :for={row <- @events} id={"event-#{row.event.stream_version}"}>
                    <:cell class="text-right tabular-nums">
                      <.link patch={page_path(assigns, event: row.event.stream_version)} class="hover:underline">
                        {number(row.event.stream_version)}
                      </.link>
                    </:cell>
                    <:cell>
                      <.link
                        patch={page_path(assigns, event: row.event.stream_version)}
                        class="font-medium hover:underline"
                        title={row.event.type}
                      >
                        {short_type(row.event.type)}
                      </.link>
                    </:cell>
                    <:cell class="text-foreground-softer whitespace-nowrap tabular-nums">{time(row.event.created_at)}</:cell>
                    <:cell :if={Enum.any?(@events, &original?(&1.event))} class="font-mono text-xs">
                      <.link
                        :if={original?(row.event)}
                        navigate={stream_path(@base_path, row.event.original_stream_id)}
                        class="hover:underline"
                      >
                        {row.event.original_stream_id} @ {row.event.original_stream_version}
                      </.link>
                    </:cell>
                    <:cell class="text-foreground-softer text-right tabular-nums">
                      {plural(row.metadata_keys, "key")}
                    </:cell>
                    <:cell class="text-right tabular-nums">
                      <.badge :if={row.large?} size="sm" color="warning">large</.badge>
                      {bytes(row.data_size)}
                    </:cell>
                    <:cell class="text-right">
                      <.button
                        size="xs"
                        variant="ghost"
                        phx-click="download"
                        phx-value-version={row.event.stream_version}
                        title="Download as JSON"
                      >
                        JSON ↓
                      </.button>
                    </:cell>
                  </.table_row>
                </.table_body>
              </.table>
              <div :if={@events == []} class="text-foreground-softer p-6 text-center">No events on this page.</div>
            </div>
          </section>
        <% else %>
          <div class="surface rounded-base text-foreground-softer p-6 text-center" id="not-found">
            No live stream has this name. It may have been archived.
          </div>
        <% end %>

        <.sheet
          id="event-sheet"
          placement="right"
          open={@info != nil and @selected != nil}
          on_close={JS.patch(page_path(assigns, event: nil))}
          class="w-full max-w-3xl"
        >
          <div :if={@selected} id="event-detail" class="space-y-6 pr-6">
            <div>
              <div class="text-foreground-softer text-xs">Event {number(@selected.event.stream_version)}</div>
              <h2 class="mt-1 break-all text-lg font-semibold">{@selected.event.type}</h2>
            </div>

            <dl>
              <.field label="ID"><span class="font-mono">{@selected.event.id}</span></.field>
              <.field label="Created">{time(@selected.event.created_at)}</.field>
              <.field label="Stream">
                <span class="font-mono">{@selected.event.stream_id} @ {@selected.event.stream_version}</span>
              </.field>
              <.field :if={original?(@selected.event)} label="Original stream">
                <span class="font-mono">
                  {@selected.event.original_stream_id} @ {@selected.event.original_stream_version}
                </span>
              </.field>
            </dl>

            <.button
              size="sm"
              variant="outline"
              phx-click="download"
              phx-value-version={@selected.event.stream_version}
            >
              Download JSON
            </.button>

            <.json_block title="Metadata" id="event-metadata" json={@selected.metadata} />
            <.json_block title="Data" id="event-data" json={@selected.data} />
          </div>
        </.sheet>
      </.page>
      """
    end
  end
end
