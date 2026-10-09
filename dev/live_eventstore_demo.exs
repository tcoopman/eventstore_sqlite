# Serves live_eventstore on http://localhost:4000/eventstore, on the database
# named by DB (default dev.db). Adds a few demo streams to an empty store.
#
#     DB=demo.db mix ecto.create && DB=demo.db mix ecto.migrate
#     DB=demo.db mix run dev/live_eventstore_demo.exs

defmodule DemoWeb.Router do
  use Phoenix.Router

  import EventstoreSqlite.LiveEventstore.Router

  pipeline :browser do
    plug(:fetch_session)
    plug(:protect_from_forgery)
  end

  scope "/" do
    pipe_through(:browser)
    live_eventstore("/eventstore")
  end
end

defmodule DemoWeb.ErrorHTML do
  def render(template, _assigns), do: Phoenix.Controller.status_message_from_template(template)
end

defmodule DemoWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :eventstore_sqlite

  @session_options [store: :cookie, key: "_live_eventstore_demo", signing_salt: "demo_salt"]

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]])

  plug(Plug.Parsers, parsers: [:urlencoded], pass: ["*/*"])
  plug(Plug.Session, @session_options)
  plug(DemoWeb.Router)
end

port = String.to_integer(System.get_env("PORT", "4000"))

Application.put_env(:eventstore_sqlite, DemoWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {127, 0, 0, 1}, port: port],
  server: true,
  render_errors: [formats: [html: DemoWeb.ErrorHTML], layout: false],
  secret_key_base: String.duplicate("live_eventstore_demo", 4),
  live_view: [signing_salt: "live_eventstore_demo"]
)

if EventstoreSqlite.list_streams() == [] do
  for {stream, count} <- [
        {"orders:1001", 12},
        {"orders:1002", 3},
        {"venue:gent", 140},
        {"venue:brussels", 57},
        {"tickets:A-17", 1}
      ] do
    events = Enum.map(1..count, &%EventstoreSqlite.Sync.DevLoad.Event{text: "#{stream} #{&1}", at: DateTime.utc_now()})
    :ok = EventstoreSqlite.append_to_stream(stream, events)
  end
end

{:ok, _} = Supervisor.start_link([DemoWeb.Endpoint], strategy: :one_for_one)
IO.puts("live_eventstore on http://localhost:#{port}/eventstore")
Process.sleep(:infinity)
