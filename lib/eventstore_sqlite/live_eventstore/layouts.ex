if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule EventstoreSqlite.LiveEventstore.Layouts do
    @moduledoc false
    use Phoenix.Component

    def root(assigns) do
      ~H"""
      <!DOCTYPE html>
      <html lang="en">
        <head>
          <meta charset="utf-8" />
          <meta name="viewport" content="width=device-width, initial-scale=1" />
          <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
          <title>{assigns[:page_title] || "live_eventstore"}</title>
          <style><%= Phoenix.HTML.raw(css()) %></style>
          <script defer src={@base_path <> "/assets/live_eventstore.js"}>
          </script>
        </head>
        <body data-live-socket-path={@live_socket_path}>
          {@inner_content}
        </body>
      </html>
      """
    end

    defp css do
      """
      :root { --bg: #f7f7f8; --panel: #fff; --text: #1d1d22; --muted: #6b6b76; --line: #e3e3e8;
              --accent: #4f46e5; --accent-soft: #eef0ff; --warn: #b45309; --bad: #b91c1c; }
      @media (prefers-color-scheme: dark) {
        :root { --bg: #131316; --panel: #1c1c21; --text: #ececf1; --muted: #9b9ba8; --line: #2e2e36;
                --accent: #8b85ff; --accent-soft: #26244a; --warn: #f59e0b; --bad: #f87171; }
      }
      * { box-sizing: border-box; }
      body { margin: 0; background: var(--bg); color: var(--text);
             font: 14px/1.45 ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif; }
      header { display: flex; align-items: baseline; gap: 16px; flex-wrap: wrap;
               padding: 14px 24px; background: var(--panel); border-bottom: 1px solid var(--line); }
      header h1 { margin: 0; font-size: 17px; }
      header .node { color: var(--muted); }
      header .right { margin-left: auto; display: flex; gap: 8px; align-items: center; color: var(--muted); }
      main { padding: 20px 24px; max-width: 1280px; }
      .cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(160px, 1fr)); gap: 12px; margin-bottom: 20px; }
      .card { background: var(--panel); border: 1px solid var(--line); border-radius: 8px; padding: 12px 14px; }
      .card .label { color: var(--muted); font-size: 12px; text-transform: uppercase; letter-spacing: .04em; }
      .card .value { font-size: 22px; font-variant-numeric: tabular-nums; margin-top: 2px; }
      .card .sub { color: var(--muted); font-size: 12px; }
      .badge { display: inline-block; padding: 1px 8px; border-radius: 999px; font-size: 12px;
               background: var(--accent-soft); color: var(--accent); }
      .badge.bad { background: transparent; border: 1px solid var(--bad); color: var(--bad); }
      .toolbar { display: flex; gap: 12px; align-items: center; flex-wrap: wrap; margin-bottom: 12px; }
      .toolbar input[type=search] { flex: 1 1 280px; padding: 7px 10px; border: 1px solid var(--line);
               border-radius: 6px; background: var(--panel); color: var(--text); font: inherit; }
      select { padding: 4px 6px; border: 1px solid var(--line); border-radius: 6px; background: var(--panel);
               color: var(--text); font: inherit; }
      .count { color: var(--muted); }
      table { width: 100%; border-collapse: collapse; background: var(--panel); border: 1px solid var(--line);
              border-radius: 8px; overflow: hidden; }
      th, td { text-align: left; padding: 8px 12px; border-bottom: 1px solid var(--line); }
      th { font-size: 12px; text-transform: uppercase; letter-spacing: .04em; color: var(--muted); font-weight: 600; }
      th a { color: inherit; text-decoration: none; }
      th a.active { color: var(--text); }
      td.num, th.num { text-align: right; font-variant-numeric: tabular-nums; }
      td.name { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; word-break: break-all; }
      td.time { color: var(--muted); white-space: nowrap; font-variant-numeric: tabular-nums; }
      tr.system td.name { color: var(--muted); }
      tbody tr:last-child td { border-bottom: 0; }
      .empty { padding: 32px; text-align: center; color: var(--muted); }
      .pager { display: flex; gap: 12px; align-items: center; justify-content: flex-end; margin-top: 12px; color: var(--muted); }
      .pager a { color: var(--accent); text-decoration: none; }
      .pager .disabled { opacity: .4; }
      """
    end
  end
end
