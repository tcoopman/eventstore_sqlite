defmodule EventstoreSqlite.LiveEventstoreTest do
  use ExUnit.Case
  use EventstoreSqlite.DataCase

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias EventstoreSqlite.LiveEventstore.Overview
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

  defp names(%{entries: entries}), do: Enum.map(entries, & &1.stream_id)

  describe "Overview" do
    setup do
      :ok = EventstoreSqlite.append_to_stream("orders:1", notes(3))
      :ok = EventstoreSqlite.append_to_stream("orders:2", notes(1))
      :ok = EventstoreSqlite.append_to_stream("venue:100%_off", notes(2))
      :ok = EventstoreSqlite.append_to_stream("gone", notes(1))
      :ok = EventstoreSqlite.archive_stream("gone")
    end

    test "summary counts application streams, their events, and archives" do
      assert %{streams: 3, events: 6, archived_streams: 1, all_position: 7, sync: %{enabled: false}} =
               Overview.summary()
    end

    test "lists application streams by name; system streams only on request" do
      assert names(Overview.streams()) == ["orders:1", "orders:2", "venue:100%_off"]
      assert names(Overview.streams(system: true)) == ["$all", "$archives", "orders:1", "orders:2", "venue:100%_off"]
    end

    test "each entry has its event count and timestamps" do
      [entry | _] = Overview.streams().entries
      assert %{stream_id: "orders:1", events: 3, system?: false, owner: nil} = entry
      assert entry.created_at =~ ~r/^\d{4}-\d\d-\d\dT/
      assert entry.last_event_at =~ ~r/^\d{4}-\d\d-\d\dT/
    end

    test "filters by name, treating % and _ literally" do
      assert names(Overview.streams(search: "orders")) == ["orders:1", "orders:2"]
      assert names(Overview.streams(search: "100%_")) == ["venue:100%_off"]
      assert names(Overview.streams(search: "0_o")) == []
    end

    test "sorts and pages" do
      assert names(Overview.streams(sort: :events, order: :desc)) == ["orders:1", "venue:100%_off", "orders:2"]

      assert %{entries: [%{stream_id: "orders:2"}], total: 3, page: 2, pages: 3} =
               Overview.streams(per_page: 1, page: 2)
    end

    test "shows the owner of each stream once sync is enabled" do
      :ok = EventstoreSqlite.Sync.enable("test-node")
      assert Enum.map(Overview.streams().entries, & &1.owner) == List.duplicate({"test-node", 0}, 3)
      assert %{enabled: true, node_id: "test-node", home?: true} = Overview.summary().sync
    end
  end

  describe "the page" do
    setup do
      :ok = EventstoreSqlite.append_to_stream("orders:1", notes(3))
      :ok = EventstoreSqlite.append_to_stream("venue:1", notes(1))
    end

    test "renders the overview, statically and connected", %{conn: conn} do
      html = conn |> get("/eventstore") |> html_response(200)
      assert html =~ "orders:1"
      assert html =~ ~s(src="/eventstore/assets/live_eventstore.js")
      assert html =~ ~s(data-live-socket-path="/live")

      {:ok, view, _html} = live(conn, "/eventstore")
      assert view |> element("#summary-streams") |> render() =~ ">2<"
      assert view |> element("#streams") |> render() =~ "venue:1"
    end

    test "filters as you type and keeps the filter in the URL", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/eventstore")

      view |> form("#filter", search: "venue") |> render_change()
      assert_patch(view, "/eventstore?search=venue")
      table = view |> element("#streams") |> render()
      assert table =~ "venue:1"
      refute table =~ "orders:1"
    end

    test "sorts by a column, toggling the order", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/eventstore?sort=events&order=desc")
      rows = view |> element("#streams tbody") |> render()
      assert :binary.match(rows, "orders:1") < :binary.match(rows, "venue:1")

      view |> element("th a", "Events") |> render_click()
      assert_patch(view, "/eventstore?sort=events")
    end

    test "shows system streams on request", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/eventstore?system=true")
      assert view |> element("#streams") |> render() =~ "$all"
    end

    test "picks up new streams on refresh", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/eventstore")
      :ok = EventstoreSqlite.append_to_stream("later", notes(1))
      send(view.pid, :refresh)
      assert view |> element("#streams") |> render() =~ "later"
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
