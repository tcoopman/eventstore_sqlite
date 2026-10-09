if Code.ensure_loaded?(Phoenix.LiveView) and Code.ensure_loaded?(Fluxon) do
  defmodule EventstoreSqlite.LiveEventstore.Layouts do
    @moduledoc false
    use Phoenix.Component
    use Fluxon, only: [:badge, :button]

    import EventstoreSqlite.LiveEventstore.Helpers, only: [root_path: 1]

    alias EventstoreSqlite.LiveEventstore.Assets

    def root(assigns) do
      ~H"""
      <!DOCTYPE html>
      <html lang="en">
        <head>
          <meta charset="utf-8" />
          <meta name="viewport" content="width=device-width, initial-scale=1" />
          <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
          <title>{assigns[:page_title] || "live_eventstore"}</title>
          <link rel="stylesheet" href={Assets.path(@base_path, :css)} />
          <script defer src={Assets.path(@base_path, :js)}>
          </script>
        </head>
        <body data-live-socket-path={@live_socket_path} class="bg-sunken text-foreground min-h-screen text-sm antialiased">
          {@inner_content}
        </body>
      </html>
      """
    end

    attr :base_path, :string, required: true
    attr :sync, :map, required: true
    slot :inner_block, required: true

    def page(assigns) do
      ~H"""
      <header class="bg-base border-base flex flex-wrap items-center gap-x-4 gap-y-2 border-b px-6 py-3">
        <.link navigate={root_path(@base_path)} class="text-foreground text-base font-semibold">
          live_eventstore
        </.link>
        <span class="text-foreground-softer flex items-center gap-2">
          <%= if @sync.enabled do %>
            node <span class="text-foreground font-medium">{@sync.node_id}</span>
            <.badge size="sm" color="info">
              {if @sync.home?, do: "home", else: "peer of #{@sync.home}"}
            </.badge>
            <.badge :if={@sync.diverged} size="sm" color="danger" variant="solid">
              diverged
            </.badge>
          <% else %>
            single node
          <% end %>
        </span>
        <span class="text-foreground-softest ml-auto flex items-center gap-1.5 text-xs">
          <span class="bg-success size-1.5 rounded-full"></span> updates live
        </span>
      </header>
      <main class="mx-auto max-w-7xl space-y-8 px-6 py-6">
        {render_slot(@inner_block)}
      </main>
      """
    end

    attr :label, :string, required: true
    attr :id, :string, default: nil
    slot :inner_block, required: true
    slot :sub

    def card(assigns) do
      ~H"""
      <div class="surface rounded-base p-4">
        <div class="text-foreground-softer text-xs font-medium uppercase tracking-wide">{@label}</div>
        <div id={@id} class="mt-1 text-xl font-semibold tabular-nums">{render_slot(@inner_block)}</div>
        <div :if={@sub != []} class="text-foreground-softer mt-0.5 text-xs">{render_slot(@sub)}</div>
      </div>
      """
    end

    attr :patch, :any, default: nil, doc: "where it leads; `nil` or `false` disables it"
    slot :inner_block, required: true

    def pager_button(%{patch: patch} = assigns) when patch in [nil, false] do
      ~H"""
      <.button size="sm" variant="outline" disabled class="opacity-50">{render_slot(@inner_block)}</.button>
      """
    end

    def pager_button(assigns) do
      ~H"""
      <.button size="sm" variant="outline" patch={@patch}>{render_slot(@inner_block)}</.button>
      """
    end

    attr :title, :string, required: true
    slot :inner_block

    def section_title(assigns) do
      ~H"""
      <div class="mb-3 flex items-center justify-between gap-4">
        <h2 class="text-foreground-softer text-xs font-semibold uppercase tracking-wide">{@title}</h2>
        {render_slot(@inner_block)}
      </div>
      """
    end
  end
end
