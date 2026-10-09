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
      assert html =~ ~s(src="/eventstore/assets/live_eventstore.js")
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
      assert conn |> get("/admin/store") |> html_response(200) =~ ~s(src="/admin/store/assets/live_eventstore.js")
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
end
