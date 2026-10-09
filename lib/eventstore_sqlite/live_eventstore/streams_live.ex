if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule EventstoreSqlite.LiveEventstore.StreamsLive do
    @moduledoc false
    use Phoenix.LiveView

    alias EventstoreSqlite.LiveEventstore.Overview

    @refresh_options [{"Off", 0}, {"1s", 1_000}, {"5s", 5_000}, {"15s", 15_000}]
    @default_refresh 5_000
    @sorts %{"name" => :name, "events" => :events, "created" => :created}

    @impl true
    def mount(_params, session, socket) do
      socket =
        assign(socket,
          base_path: session["base_path"],
          live_socket_path: session["live_socket_path"],
          page_title: "Streams · live_eventstore",
          refresh: @default_refresh,
          refresh_options: @refresh_options,
          timer: nil
        )

      {:ok, schedule_refresh(socket)}
    end

    @impl true
    def handle_params(params, _uri, socket) do
      filters = %{
        search: params |> Map.get("search", "") |> String.trim(),
        sort: Map.get(@sorts, params["sort"], :name),
        order: if(params["order"] == "desc", do: :desc, else: :asc),
        page: positive_integer(params["page"], 1),
        system: params["system"] == "true"
      }

      {:noreply, socket |> assign(filters: filters) |> load()}
    end

    @impl true
    def handle_event("filter", params, socket) do
      filters = %{socket.assigns.filters | search: params["search"] || "", system: params["system"] == "true", page: 1}
      {:noreply, push_patch(socket, to: path(socket.assigns.base_path, filters))}
    end

    def handle_event("set_refresh", %{"refresh" => refresh}, socket) do
      socket = assign(socket, refresh: positive_integer(refresh, 0))
      {:noreply, schedule_refresh(socket)}
    end

    @impl true
    def handle_info(:refresh, socket), do: {:noreply, socket |> load() |> schedule_refresh()}

    defp load(socket) do
      filters = socket.assigns.filters

      streams =
        Overview.streams(
          search: filters.search,
          sort: filters.sort,
          order: filters.order,
          page: filters.page,
          system: filters.system
        )

      assign(socket, summary: Overview.summary(), page: streams)
    end

    defp schedule_refresh(socket) do
      if socket.assigns.timer, do: Process.cancel_timer(socket.assigns.timer)

      timer =
        if connected?(socket) and socket.assigns.refresh > 0,
          do: Process.send_after(self(), :refresh, socket.assigns.refresh)

      assign(socket, timer: timer)
    end

    defp positive_integer(nil, default), do: default

    defp positive_integer(value, default) do
      case Integer.parse(value) do
        {integer, ""} when integer >= 0 -> integer
        _ -> default
      end
    end

    defp path(base_path, filters) do
      query =
        Enum.reject(
          [
            search: if(filters.search != "", do: filters.search),
            system: if(filters.system, do: "true"),
            sort: if(filters.sort != :name, do: Atom.to_string(filters.sort)),
            order: if(filters.order == :desc, do: "desc"),
            page: if(filters.page > 1, do: Integer.to_string(filters.page))
          ],
          fn {_key, value} -> is_nil(value) end
        )

      root = if base_path == "", do: "/", else: base_path
      if query == [], do: root, else: root <> "?" <> URI.encode_query(query)
    end

    defp sort_path(base_path, filters, sort) do
      order = if filters.sort == sort and filters.order == :asc, do: :desc, else: :asc
      path(base_path, %{filters | sort: sort, order: order, page: 1})
    end

    defp sort_marker(filters, sort) do
      cond do
        filters.sort != sort -> ""
        filters.order == :asc -> " ↑"
        true -> " ↓"
      end
    end

    defp number(integer) do
      integer
      |> Integer.to_string()
      |> String.reverse()
      |> String.replace(~r/(\d{3})(?=\d)/, "\\1 ")
      |> String.reverse()
    end

    defp time(nil), do: "—"
    defp time(timestamp), do: timestamp |> String.replace("T", " ") |> String.trim_trailing("Z")

    defp owner({node_id, 0}), do: node_id
    defp owner({node_id, generation}), do: "#{node_id} · gen #{generation}"

    @impl true
    def render(assigns) do
      ~H"""
      <header>
        <h1>live_eventstore</h1>
        <span class="node">
          <%= if @summary.sync.enabled do %>
            node <strong>{@summary.sync.node_id}</strong>
            <span class="badge">{if @summary.sync.home?, do: "home", else: "peer of #{@summary.sync.home}"}</span>
            <span :if={@summary.sync.diverged} class="badge bad">diverged</span>
          <% else %>
            single node
          <% end %>
        </span>
        <form class="right" phx-change="set_refresh">
          <label for="refresh">Refresh</label>
          <select id="refresh" name="refresh">
            <option :for={{label, value} <- @refresh_options} value={value} selected={value == @refresh}>
              {label}
            </option>
          </select>
        </form>
      </header>

      <main>
        <section class="cards">
          <div class="card">
            <div class="label">Streams</div>
            <div class="value" id="summary-streams">{number(@summary.streams)}</div>
            <div class="sub">{@summary.system_streams} system</div>
          </div>
          <div class="card">
            <div class="label">Events</div>
            <div class="value" id="summary-events">{number(@summary.events)}</div>
            <div class="sub">in live streams</div>
          </div>
          <div class="card">
            <div class="label">$all position</div>
            <div class="value">{number(@summary.all_position)}</div>
            <div class="sub">next position on this node</div>
          </div>
          <div class="card">
            <div class="label">Archived streams</div>
            <div class="value">{number(@summary.archived_streams)}</div>
          </div>
          <div :if={@summary.sync.enabled} class="card">
            <div class="label">Sync</div>
            <div class="value">{length(@summary.sync.peers)} peer{if length(@summary.sync.peers) == 1, do: "", else: "s"}</div>
            <div class="sub">{@summary.sync.assignments} assignment{if @summary.sync.assignments == 1, do: "", else: "s"}</div>
          </div>
        </section>

        <form id="filter" class="toolbar" phx-change="filter" phx-submit="filter">
          <input
            type="search"
            name="search"
            value={@filters.search}
            placeholder="Filter streams by name"
            phx-debounce="250"
            autocomplete="off"
          />
          <label>
            <input type="hidden" name="system" value="false" />
            <input type="checkbox" name="system" value="true" checked={@filters.system} /> system streams
          </label>
          <span class="count" id="stream-count">
            {number(@page.total)} stream{if @page.total == 1, do: "", else: "s"}
          </span>
        </form>

        <table id="streams">
          <thead>
            <tr>
              <th><.link patch={sort_path(@base_path, @filters, :name)} class={@filters.sort == :name && "active"}>Stream{sort_marker(@filters, :name)}</.link></th>
              <th class="num"><.link patch={sort_path(@base_path, @filters, :events)} class={@filters.sort == :events && "active"}>Events{sort_marker(@filters, :events)}</.link></th>
              <th><.link patch={sort_path(@base_path, @filters, :created)} class={@filters.sort == :created && "active"}>Created{sort_marker(@filters, :created)}</.link></th>
              <th>Last event</th>
              <th :if={@summary.sync.enabled}>Owner</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={stream <- @page.entries} class={stream.system? && "system"}>
              <td class="name">{stream.stream_id}</td>
              <td class="num">{number(stream.events)}</td>
              <td class="time">{time(stream.created_at)}</td>
              <td class="time">{time(stream.last_event_at)}</td>
              <td :if={@summary.sync.enabled}>{stream.owner && owner(stream.owner)}</td>
            </tr>
          </tbody>
        </table>
        <div :if={@page.entries == []} class="empty">No streams match.</div>

        <nav :if={@page.pages > 1} class="pager">
          <%= if @page.page > 1 do %>
            <.link patch={path(@base_path, %{@filters | page: @page.page - 1})}>← Previous</.link>
          <% else %>
            <span class="disabled">← Previous</span>
          <% end %>
          <span>Page {@page.page} of {@page.pages}</span>
          <%= if @page.page < @page.pages do %>
            <.link patch={path(@base_path, %{@filters | page: @page.page + 1})}>Next →</.link>
          <% else %>
            <span class="disabled">Next →</span>
          <% end %>
        </nav>
      </main>
      """
    end
  end
end
