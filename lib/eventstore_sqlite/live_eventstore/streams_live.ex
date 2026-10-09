if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule EventstoreSqlite.LiveEventstore.StreamsLive do
    @moduledoc false
    use Phoenix.LiveView

    alias EventstoreSqlite.Ownership
    alias EventstoreSqlite.Sync

    @page_size 50
    @history_size 15
    @fallback_refresh 30_000
    @resubscribe_after 100

    @impl true
    def mount(_params, session, socket) do
      socket =
        assign(socket,
          base_path: session["base_path"],
          live_socket_path: session["live_socket_path"],
          page_title: "live_eventstore"
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
      filters = %{search: params["search"] || "", system: params["system"] == "true", after: nil}
      {:noreply, push_patch(socket, to: path(socket.assigns.base_path, filters))}
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
      Process.send_after(self(), :resubscribe, @resubscribe_after)
      {:noreply, socket}
    end

    def handle_info(:resubscribe, socket) do
      subscribe()
      {:noreply, socket |> load_streams() |> load_sync()}
    catch
      :exit, _not_restarted_yet ->
        Process.send_after(self(), :resubscribe, @resubscribe_after)
        {:noreply, socket}
    end

    defp subscribe do
      Process.monitor(EventstoreSqlite.Changes)
      :ok = EventstoreSqlite.subscribe_to_changes(self())
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

    defp path(base_path, filters) do
      query =
        Enum.reject(
          [
            search: if(filters.search != "", do: filters.search),
            system: if(filters.system, do: "true"),
            after: filters.after
          ],
          fn {_key, value} -> is_nil(value) end
        )

      root = if base_path == "", do: "/", else: base_path
      if query == [], do: root, else: root <> "?" <> URI.encode_query(query)
    end

    defp number(nil), do: "—"

    defp number(integer) do
      integer
      |> Integer.to_string()
      |> String.reverse()
      |> String.replace(~r/(\d{3})(?=\d)/, "\\1 ")
      |> String.reverse()
    end

    defp time(nil), do: "—"
    defp time(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S")

    defp owner(nil), do: ""
    defp owner({node_id, 0}), do: node_id
    defp owner({node_id, generation}), do: "#{node_id} · gen #{generation}"

    defp peer_state_class(state) when state in [:connected, :drained], do: "badge"
    defp peer_state_class(_state), do: "badge bad"

    defp event_name(%{data: %type{}}), do: type |> Module.split() |> List.last()

    defp event_fields(%{data: data}) do
      data
      |> Map.from_struct()
      |> Enum.map_join(", ", fn {key, value} -> "#{key}: #{inspect(value)}" end)
    end

    defp plural(1, word), do: "1 #{word}"
    defp plural(count, word), do: "#{number(count)} #{word}s"

    @impl true
    def render(assigns) do
      ~H"""
      <header>
        <h1>live_eventstore</h1>
        <span class="node">
          <%= if @sync.enabled do %>
            node <strong>{@sync.node_id}</strong>
            <span class="badge">{if @sync.home?, do: "home", else: "peer of #{@sync.home}"}</span>
            <span :if={@sync.diverged} class="badge bad">diverged</span>
          <% else %>
            single node
          <% end %>
        </span>
        <span class="right">updates live</span>
      </header>

      <main>
        <section :if={@sync.enabled} id="sync">
          <div class="cards">
            <div class="card">
              <div class="label">Change log</div>
              <div class="value" id="log-entries">{plural(@sync.log.entries, "entry")}</div>
              <div class="sub">retained for peers · head {number(@sync.head)}</div>
            </div>
            <div class="card">
              <div class="label">Peers</div>
              <div class="value">{map_size(@sync.peers)}</div>
              <div class="sub">{plural(length(@assignments), "assignment")}</div>
            </div>
            <div :if={@sync.diverged} class="card">
              <div class="label">Diverged</div>
              <div class="value">revoked by {@sync.diverged.revoked_by}</div>
              <div class="sub">this node refuses every write</div>
            </div>
          </div>

          <h2>Peers</h2>
          <table id="peers">
            <thead>
              <tr>
                <th>Peer</th>
                <th>State</th>
                <th class="num">Lag</th>
                <th>Last applied</th>
                <th>Last success</th>
                <th class="num">Acked</th>
                <th class="num">Quarantined</th>
                <th>Owns</th>
                <th>Problem</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={{peer, status} <- Enum.sort(@sync.peers)}>
                <td class="name">{peer}</td>
                <td><span class={peer_state_class(status.state)}>{status.state}</span></td>
                <td class="num">{number(status.lag)}</td>
                <td class="time">{time(status.last_applied_at)}</td>
                <td class="time">{time(status.last_success)}</td>
                <td class="num">{number(status.acked)}</td>
                <td class="num">{number(status.quarantined)}</td>
                <td>{Enum.map_join(status.owns, ", ", &"gen #{&1}")}</td>
                <td class="problem">
                  <span :if={status.halted}>halted: {inspect(status.halted)}</span>
                  <span :if={!status.halted && status.last_error}>{inspect(status.last_error)}</span>
                </td>
              </tr>
            </tbody>
          </table>
          <div :if={@sync.peers == %{}} class="empty">No peers.</div>

          <%= if @assignments != [] do %>
            <h2>Assignments</h2>
            <table id="assignments">
              <thead>
                <tr><th class="num">Generation</th><th>Streams</th><th>Owner</th></tr>
              </thead>
              <tbody>
                <tr :for={assignment <- @assignments}>
                  <td class="num">{assignment.generation}</td>
                  <td class="name">{assignment.selector}</td>
                  <td>{assignment.owner}</td>
                </tr>
              </tbody>
            </table>
          <% end %>
        </section>

        <h2>Streams</h2>
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
        </form>

        <table id="streams">
          <thead>
            <tr>
              <th>Stream</th>
              <th class="num">Version</th>
              <th>Created</th>
              <th>Last event</th>
              <th :if={@sync.enabled}>Owner</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={stream <- @page.entries} class={stream.stream_id in EventstoreSqlite.system_streams() && "system"}>
              <td class="name">{stream.stream_id}</td>
              <td class="num">{number(stream.version)}</td>
              <td class="time">{time(stream.created_at)}</td>
              <td class="time">{time(stream.last_event_at)}</td>
              <td :if={@sync.enabled}>{owner(stream.owner)}</td>
            </tr>
          </tbody>
        </table>
        <div :if={@page.entries == []} class="empty">No streams match.</div>

        <nav :if={@filters.after || @page.next} class="pager">
          <%= if @filters.after do %>
            <.link patch={path(@base_path, %{@filters | after: nil})}>← First page</.link>
          <% else %>
            <span class="disabled">← First page</span>
          <% end %>
          <%= if @page.next do %>
            <.link patch={path(@base_path, %{@filters | after: @page.next})}>Next →</.link>
          <% else %>
            <span class="disabled">Next →</span>
          <% end %>
        </nav>

        <section :if={@history != []} id="history">
          <h2>Sync history</h2>
          <table>
            <tbody>
              <tr :for={event <- @history}>
                <td class="time">{time(event.created_at)}</td>
                <td>{event_name(event)}</td>
                <td class="fields">{event_fields(event)}</td>
              </tr>
            </tbody>
          </table>
        </section>
      </main>
      """
    end
  end
end
