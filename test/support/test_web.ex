defmodule EventstoreSqlite.TestWeb.Router do
  @moduledoc false
  use Phoenix.Router

  import EventstoreSqlite.LiveEventstore.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:fetch_session)
    plug(:protect_from_forgery)
  end

  scope "/" do
    pipe_through(:browser)
    live_eventstore("/eventstore")
  end

  scope "/admin" do
    pipe_through(:browser)
    live_eventstore("/store", live_session_name: :nested_live_eventstore)
  end
end

defmodule EventstoreSqlite.TestWeb.Endpoint do
  @moduledoc false
  use Phoenix.Endpoint, otp_app: :eventstore_sqlite

  @session_options [store: :cookie, key: "_live_eventstore_test", signing_salt: "live_eventstore"]

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]])

  plug(Plug.Session, @session_options)
  plug(EventstoreSqlite.TestWeb.Router)
end

defmodule EventstoreSqlite.TestWeb.ErrorHTML do
  @moduledoc false

  def render(template, assigns) do
    "#{template}: " <> Exception.format(assigns[:kind] || :error, assigns[:reason], assigns[:stack] || [])
  end
end
