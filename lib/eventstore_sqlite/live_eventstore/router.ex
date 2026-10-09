if Code.ensure_loaded?(Phoenix.LiveView) and Code.ensure_loaded?(Fluxon) do
  defmodule EventstoreSqlite.LiveEventstore.Router do
    @moduledoc """
    Mounts live_eventstore, a read-only LiveView dashboard of the event store,
    in a Phoenix router.

        import EventstoreSqlite.LiveEventstore.Router

        scope "/" do
          pipe_through :browser
          live_eventstore "/eventstore"
        end

    It needs `phoenix_live_view` and `fluxon` in the application, a
    `:browser`-style pipeline (session and CSRF protection), and the LiveView
    socket in the endpoint, as every LiveView app has:

        socket "/live", Phoenix.LiveView.Socket,
          websocket: [connect_info: [session: @session_options]]

    The pages show stream names, every event's data and metadata, and with
    sync enabled node names and replication errors, so put them behind
    authentication, as you would `Phoenix.LiveDashboard`. It serves its own
    stylesheet and JavaScript (with Fluxon's), under `<path>/assets`.

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

          alias EventstoreSqlite.LiveEventstore.Assets

          {session_name, session_opts} = EventstoreSqlite.LiveEventstore.Router.__options__(base_path, opts)

          get("/assets/live_eventstore.js", Assets, :js, as: :live_eventstore_asset)
          get("/assets/live_eventstore.css", Assets, :css, as: :live_eventstore_css)

          live_session session_name, session_opts do
            live("/", EventstoreSqlite.LiveEventstore.StreamsLive, :index, as: :live_eventstore)
            live("/stream", EventstoreSqlite.LiveEventstore.StreamLive, :show, as: :live_eventstore_stream)
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
      var liveSocket = new LiveView.LiveSocket(socketPath, Phoenix.Socket, {
        params: {_csrf_token: csrf},
        hooks: Fluxon.Hooks,
        dom: {onBeforeElUpdated: function (from, to) { Fluxon.DOM.onBeforeElUpdated(from, to); }}
      });
      liveSocket.connect();
      window.liveEventstoreSocket = liveSocket;

      window.addEventListener("phx:live_eventstore:download", function (event) {
        var blob = new Blob([event.detail.content], {type: "application/json"});
        var link = document.createElement("a");
        link.href = URL.createObjectURL(blob);
        link.download = event.detail.filename;
        document.body.appendChild(link);
        link.click();
        link.remove();
        URL.revokeObjectURL(link.href);
      });
    })();
    """

    @fluxon_prelude "var Fluxon = (function () { var module = {exports: {}}, exports = module.exports;"
    @fluxon_postlude "return module.exports; })();"

    @impl true
    def init(asset), do: asset

    @impl true
    def call(conn, :js), do: send_asset(conn, "application/javascript", js())
    def call(conn, :css), do: send_asset(conn, "text/css", css())

    @doc """
    The path of `asset` under `base_path`, with a digest of its content, so a
    browser fetches it again after an upgrade instead of using its cached copy.
    """
    def path(base_path, :js), do: base_path <> "/assets/live_eventstore.js?v=" <> digest(js())
    def path(base_path, :css), do: base_path <> "/assets/live_eventstore.css?v=" <> digest(css())

    defp digest(body), do: :md5 |> :crypto.hash(body) |> Base.encode16(case: :lower) |> binary_part(0, 12)

    defp send_asset(conn, content_type, body) do
      conn
      |> put_private(:plug_skip_csrf_protection, true)
      |> put_resp_content_type(content_type)
      |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
      |> send_resp(200, body)
      |> halt()
    end

    defp css do
      cached(:css, fn -> File.read!(Application.app_dir(:eventstore_sqlite, "priv/static/live_eventstore.css")) end)
    end

    defp js do
      cached(:js, fn ->
        Enum.join(
          [
            File.read!(Application.app_dir(:phoenix, "priv/static/phoenix.min.js")),
            File.read!(Application.app_dir(:phoenix_live_view, "priv/static/phoenix_live_view.min.js")),
            @fluxon_prelude,
            File.read!(Application.app_dir(:fluxon, "priv/static/fluxon.cjs.js")),
            @fluxon_postlude,
            @init
          ],
          "\n;\n"
        )
      end)
    end

    defp cached(asset, build) do
      case :persistent_term.get({__MODULE__, asset}, nil) do
        nil ->
          body = build.()
          :persistent_term.put({__MODULE__, asset}, body)
          body

        body ->
          body
      end
    end
  end
end
