defmodule EventstoreSqlite.LiveEventstoreTest do
  use ExUnit.Case
  use EventstoreSqlite.DataCase

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias EventstoreSqlite.Test.Note

  @endpoint EventstoreSqlite.TestWeb.Endpoint

  setup_all do
    start_supervised!(@endpoint)
    :ok
  end

  setup do
    {:ok, conn: build_conn()}
  end

  defp notes(count), do: Enum.map(1..count, &%Note{text: "n#{&1}"})

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(20)
        eventually(fun, tries - 1)
    end
  end

  describe "the page" do
    setup do
      :ok = EventstoreSqlite.append_to_stream("orders:1", notes(3))
      :ok = EventstoreSqlite.append_to_stream("venue:1", notes(1))
    end

    test "renders the streams, statically and connected", %{conn: conn} do
      html = conn |> get("/eventstore") |> html_response(200)
      assert html =~ "orders:1"
      assert html =~ "single node"
      assert html =~ ~r|src="/eventstore/assets/live_eventstore.js\?v=[0-9a-f]{12}"|
      assert html =~ ~r|href="/eventstore/assets/live_eventstore.css\?v=[0-9a-f]{12}"|
      assert html =~ ~s(data-live-socket-path="/live")

      {:ok, view, _html} = live(conn, "/eventstore")
      table = view |> element("#streams") |> render()
      assert table =~ "venue:1"
      refute has_element?(view, "#sync")
    end

    test "filters as you type and keeps the filter in the URL", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/eventstore")

      view |> form("#filter", search: "NUE") |> render_change()
      assert_patch(view, "/eventstore?search=NUE")
      table = view |> element("#streams") |> render()
      assert table =~ "venue:1"
      refute table =~ "orders:1"
    end

    test "pages by name", %{conn: conn} do
      for i <- 1..60, do: :ok = EventstoreSqlite.append_to_stream("page:#{String.pad_leading("#{i}", 2, "0")}", notes(1))

      {:ok, view, _html} = live(conn, "/eventstore?search=page")
      assert view |> element("#streams tbody") |> render() =~ "page:50"
      refute view |> element("#streams tbody") |> render() =~ "page:51"

      view |> element(".pager a", "Next") |> render_click()
      assert_patch(view, "/eventstore?search=page&after=page%3A50")
      rows = view |> element("#streams tbody") |> render()
      assert rows =~ "page:51"
      refute rows =~ "page:50"

      view |> element(".pager a", "First page") |> render_click()
      assert_patch(view, "/eventstore?search=page")
    end

    test "shows system streams on request", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/eventstore?system=true")
      assert view |> element("#streams") |> render() =~ "$all"
    end

    test "updates when the store changes, without polling", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/eventstore")
      :ok = EventstoreSqlite.append_to_stream("later", notes(1))
      assert eventually(fn -> view |> element("#streams") |> render() =~ "later" end)
    end

    test "with sync enabled shows the node, its peers, owners and history", %{conn: conn} do
      :ok = EventstoreSqlite.Sync.enable("test-node")

      EventstoreSqlite.SyncCase.record!(%EventstoreSqlite.SystemEvents.PeerAdded{
        node_id: "secondary-node",
        pinned_seq: 0
      })

      {:ok, _} = EventstoreSqlite.Ownership.assign("venue:*", "secondary-node")

      {:ok, view, html} = live(conn, "/eventstore")
      assert html =~ "test-node"
      assert view |> element("#peers") |> render() =~ "secondary-node"
      assert view |> element("#assignments") |> render() =~ "venue:*"
      assert view |> element("#streams") |> render() =~ "secondary-node · gen 1"
      history = view |> element("#history") |> render()
      assert history =~ "SyncEnabled"
      assert history =~ "OwnershipAssigned"
    end

    test "works mounted in a nested scope", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/store")
      assert html =~ "orders:1"
      assert conn |> get("/admin/store") |> html_response(200) =~ ~r{src="/admin/store/assets/live_eventstore.js\?v=}
    end

    test "serves the compiled stylesheet", %{conn: conn} do
      conn = get(conn, "/eventstore/assets/live_eventstore.css")
      assert response_content_type(conn, :css) =~ "text/css"
      assert conn.resp_body =~ "--background-base"
    end

    test "serves the JavaScript through a pipeline with CSRF protection", %{conn: conn} do
      conn =
        conn
        |> Plug.Conn.put_private(:plug_skip_csrf_protection, false)
        |> get("/eventstore/assets/live_eventstore.js")

      assert response_content_type(conn, :js) =~ "javascript"
      assert conn.resp_body =~ "LiveSocket"
    end
  end

  describe "a stream's page" do
    defp texts(count, prefix), do: Enum.map(1..count, &%Note{text: "#{prefix}#{&1}"})

    test "links from the streams table", %{conn: conn} do
      :ok = EventstoreSqlite.append_to_stream("orders:1", notes(1))
      {:ok, view, _html} = live(conn, "/eventstore")

      {:ok, _view, html} =
        view |> element("#streams a", "orders:1") |> render_click() |> follow_redirect(conn)

      assert html =~ ~s(id="stream-name")
      assert html =~ "orders:1"
    end

    test "shows the latest events first, a page at a time", %{conn: conn} do
      :ok = EventstoreSqlite.append_to_stream("big:1", texts(60, "e"))

      {:ok, view, html} = live(conn, "/eventstore/stream?id=big%3A1")
      assert html =~ "Events 35–59"
      assert has_element?(view, "#event-59")
      refute has_element?(view, "#event-34")

      view |> element(".pager a", "Older") |> render_click()
      assert_patch(view, "/eventstore/stream?id=big%3A1&before=35")
      assert has_element?(view, "#event-34")
      assert has_element?(view, "#event-10")
      refute has_element?(view, "#event-35")

      view |> element(".pager a", "Older") |> render_click()
      assert_patch(view, "/eventstore/stream?id=big%3A1&before=10")
      assert has_element?(view, "#event-0")

      view |> element(".pager a", "Newer") |> render_click()
      assert_patch(view, "/eventstore/stream?id=big%3A1&before=35")

      view |> element(".pager a", "Latest") |> render_click()
      assert_patch(view, "/eventstore/stream?id=big%3A1")
    end

    test "keeps up with appends on the latest page", %{conn: conn} do
      :ok = EventstoreSqlite.append_to_stream("live:1", notes(1))
      {:ok, view, _html} = live(conn, "/eventstore/stream?id=live%3A1")

      :ok = EventstoreSqlite.append_to_stream("live:1", notes(1))
      assert eventually(fn -> has_element?(view, "#event-1") end)
    end

    test "shows an event's metadata and data", %{conn: conn} do
      event = %EventstoreSqlite.NewEvent{data: %Note{text: "hello"}, metadata: %{correlation_id: "c-1"}}
      :ok = EventstoreSqlite.append_to_stream("orders:1", [event])
      {:ok, view, _html} = live(conn, "/eventstore/stream?id=orders%3A1")

      view |> element("#event-0 a", "Note") |> render_click()
      assert_patch(view, "/eventstore/stream?id=orders%3A1&event=0")

      assert view |> element("#event-detail") |> render() =~ "Elixir.EventstoreSqlite.Test.Note"
      assert view |> element("#event-metadata") |> render() =~ "c-1"
      assert view |> element("#event-data") |> render() =~ "hello"
    end

    test "doesn't render a large event's data, but downloads it", %{conn: conn} do
      :ok = EventstoreSqlite.append_to_stream("orders:1", [%Note{text: String.duplicate("x", 60_000)}])
      {:ok, view, _html} = live(conn, "/eventstore/stream?id=orders%3A1&event=0")

      assert view |> element("#event-data") |> render() =~ "too big to show"
      assert view |> element("#event-0") |> render() =~ "large"

      view |> element("#event-detail button", "Download JSON") |> render_click()
      assert_push_event(view, "live_eventstore:download", %{filename: "orders_1-0.json", content: content})
      assert %{"data" => %{"text" => text}} = Jason.decode!(content)
      assert byte_size(text) == 60_000
    end

    test "every row has a download button", %{conn: conn} do
      :ok = EventstoreSqlite.append_to_stream("orders:1", notes(2))
      {:ok, view, _html} = live(conn, "/eventstore/stream?id=orders%3A1")

      view |> element("#event-1 button", "JSON") |> render_click()
      assert_push_event(view, "live_eventstore:download", %{filename: "orders_1-1.json"})
    end

    test "$all shows where each event was appended", %{conn: conn} do
      :ok = EventstoreSqlite.append_to_stream("orders:1", notes(1))
      {:ok, view, _html} = live(conn, "/eventstore/stream?id=%24all")
      assert view |> element("#event-0") |> render() =~ "orders:1 @ 0"
    end

    test "a stream that doesn't exist says so", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/eventstore/stream?id=nope")
      assert has_element?(view, "#not-found")
    end
  end
end
