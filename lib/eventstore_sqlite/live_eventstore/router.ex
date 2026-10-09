if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule EventstoreSqlite.LiveEventstore.Router do
    @moduledoc """
    Mounts live_eventstore, a read-only LiveView dashboard of the event store,
    in a Phoenix router.

        import EventstoreSqlite.LiveEventstore.Router

        scope "/" do
          pipe_through :browser
          live_eventstore "/eventstore"
        end

    It needs `phoenix_live_view` in the application, a `:browser`-style
    pipeline (session and CSRF protection), and the LiveView socket in the
    endpoint, as every LiveView app has:

        socket "/live", Phoenix.LiveView.Socket,
          websocket: [connect_info: [session: @session_options]]

    The page shows stream names and, with sync enabled, node names and
    replication errors, so put it behind authentication, as you would
    `Phoenix.LiveDashboard`.

    Options:

      * `:on_mount` — passed to `live_session`, for example an authentication
        hook;
      * `:live_socket_path` — the endpoint's LiveView socket path (default
        `"/live"`);
      * `:live_session_name` — the name of the `live_session` (default
        `:live_eventstore`), needed only to mount it twice.
    """

    defmacro live_eventstore(path, opts \\ []) do
      quote bind_quoted: binding() do
        base_path = Phoenix.Router.scoped_path(__MODULE__, path)

        scope path, alias: false, as: false do
          import Phoenix.LiveView.Router, only: [live: 4, live_session: 3]

          {session_name, session_opts} = EventstoreSqlite.LiveEventstore.Router.__options__(base_path, opts)

          get("/assets/live_eventstore.js", EventstoreSqlite.LiveEventstore.Assets, :js, as: :live_eventstore_asset)

          live_session session_name, session_opts do
            live("/", EventstoreSqlite.LiveEventstore.StreamsLive, :index, as: :live_eventstore)
          end
        end
      end
    end

    @doc false
    def __options__(base_path, opts) do
      session = %{
        "base_path" => String.trim_trailing(base_path, "/"),
        "live_socket_path" => Keyword.get(opts, :live_socket_path, "/live")
      }

      session_opts =
        [session: session, root_layout: {EventstoreSqlite.LiveEventstore.Layouts, :root}] ++
          Keyword.take(opts, [:on_mount])

      {Keyword.get(opts, :live_session_name, :live_eventstore), session_opts}
    end
  end

  defmodule EventstoreSqlite.LiveEventstore.Assets do
    @moduledoc false
    @behaviour Plug

    import Plug.Conn

    @init """
    (function () {
      var socketPath = document.body.getAttribute("data-live-socket-path") || "/live";
      var csrf = document.querySelector("meta[name='csrf-token']").getAttribute("content");
      var liveSocket = new LiveView.LiveSocket(socketPath, Phoenix.Socket, {params: {_csrf_token: csrf}});
      liveSocket.connect();
      window.liveEventstoreSocket = liveSocket;
    })();
    """

    @impl true
    def init(asset), do: asset

    @impl true
    def call(conn, :js) do
      conn
      |> put_private(:plug_skip_csrf_protection, true)
      |> put_resp_content_type("application/javascript")
      |> put_resp_header("cache-control", "public, max-age=3600")
      |> send_resp(200, js())
      |> halt()
    end

    defp js do
      case :persistent_term.get({__MODULE__, :js}, nil) do
        nil ->
          js =
            Enum.join(
              [
                File.read!(Application.app_dir(:phoenix, "priv/static/phoenix.min.js")),
                File.read!(Application.app_dir(:phoenix_live_view, "priv/static/phoenix_live_view.min.js")),
                @init
              ],
              "\n;\n"
            )

          :persistent_term.put({__MODULE__, :js}, js)
          js

        js ->
          js
      end
    end
  end
end
