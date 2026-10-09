defmodule EventstoreSqlite.LiveEventstore.PayloadTest do
  use ExUnit.Case, async: true

  alias EventstoreSqlite.LiveEventstore.Payload
  alias EventstoreSqlite.RecordedEvent
  alias EventstoreSqlite.Test.Note

  defp decoded(term), do: term |> Payload.json() |> Jason.decode!()

  test "writes plain terms as JSON" do
    assert decoded(%{"a" => 1, b: [true, nil, 1.5]}) == %{"a" => 1, "b" => [true, nil, 1.5]}
  end

  test "writes atoms, tuples and module names as strings and arrays" do
    assert decoded({:ok, :done, EventstoreSqlite}) == ["ok", "done", "EventstoreSqlite"]
  end

  test "writes dates as ISO 8601 and other structs as objects naming their module" do
    assert decoded(%{at: ~U[2026-10-09 12:00:00Z], day: ~D[2026-10-09]}) == %{
             "at" => "2026-10-09T12:00:00Z",
             "day" => "2026-10-09"
           }

    assert decoded(%Note{text: "hi"}) == %{"__struct__" => "EventstoreSqlite.Test.Note", "text" => "hi"}
  end

  test "uses a struct's String.Chars implementation" do
    assert decoded(URI.parse("https://example.com/a")) == "https://example.com/a"
  end

  test "writes binaries that aren't UTF-8 as base64, and other terms inspected" do
    assert decoded(<<255, 0>>) == %{"__binary__" => Base.encode64(<<255, 0>>)}
    assert decoded(%{{1, 2} => self()}) == %{"{1, 2}" => inspect(self())}
    assert decoded([1 | 2]) == "[1 | 2]"
  end

  test "an event's data doesn't name its struct, but nested structs do" do
    data = %Note{text: %Note{text: "inner"}}

    assert data |> Payload.data_json() |> Jason.decode!() == %{
             "text" => %{"__struct__" => "EventstoreSqlite.Test.Note", "text" => "inner"}
           }
  end

  test "an event is written with its envelope" do
    event = %RecordedEvent{
      id: "id-1",
      data: %Note{text: "hi"},
      type: "Elixir.EventstoreSqlite.Test.Note",
      stream_id: "$all",
      stream_version: 7,
      created_at: ~U[2026-10-09 12:00:00Z],
      metadata: %{correlation_id: "c"},
      original_stream_id: "notes",
      original_stream_version: 2
    }

    json = Payload.event_json(event)
    assert json =~ ~r/^\{\n  "id": "id-1",\n  "type"/

    assert %{
             "stream_id" => "$all",
             "stream_version" => 7,
             "original_stream_id" => "notes",
             "original_stream_version" => 2,
             "created_at" => "2026-10-09T12:00:00Z",
             "metadata" => %{"correlation_id" => "c"},
             "data" => %{"text" => "hi"}
           } = Jason.decode!(json)
  end
end
