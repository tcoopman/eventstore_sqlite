defmodule EventstoreSqlite.UpcasterTest do
  use ExUnit.Case
  use EventstoreSqlite.DataCase
  use TypedStruct

  alias EventstoreSqlite.NewEvent
  alias EventstoreSqlite.RecordedEvent
  alias EventstoreSqlite.Upcaster

  typedstruct module: OldScanned do
    field(:ticket_id, :string)
    field(:location, :any)
  end

  typedstruct module: Scanned do
    field(:ticket_id, :string)
    field(:location, :any)
    field(:gate, :atom)
  end

  typedstruct module: OldLocation do
    field(:name, :string)
  end

  typedstruct module: Location do
    field(:name, :string)
  end

  typedstruct module: Untouched do
    field(:text, :string)
  end

  defmodule RenameUpcaster do
    @moduledoc false
    @behaviour Upcaster

    @impl true
    def upcast(event) do
      Upcaster.rename(event, %{
        EventstoreSqlite.UpcasterTest.OldScanned => EventstoreSqlite.UpcasterTest.Scanned,
        EventstoreSqlite.UpcasterTest.OldLocation => EventstoreSqlite.UpcasterTest.Location
      })
    end
  end

  defmodule GateUpcaster do
    @moduledoc false
    @behaviour Upcaster

    alias EventstoreSqlite.UpcasterTest.Scanned

    @impl true
    def upcast(%RecordedEvent{data: %{__struct__: Scanned} = data} = event) when not is_map_key(data, :gate) do
      %{event | data: Map.put(data, :gate, :unknown)}
    end

    def upcast(event), do: event
  end

  defmodule EnvelopeUpcaster do
    @moduledoc false
    @behaviour Upcaster

    @impl true
    def upcast(event) do
      %{
        event
        | id: Ecto.UUID.generate(),
          stream_id: "elsewhere",
          stream_version: 99,
          original_stream_id: "elsewhere",
          original_stream_version: 99,
          created_at: ~U[2000-01-01 00:00:00Z],
          type: "Elixir.Wrong",
          metadata: Map.put(event.metadata, :upcasted, true)
      }
    end
  end

  defmodule BrokenUpcaster do
    @moduledoc false
    @behaviour Upcaster

    @impl true
    def upcast(event), do: %{event | data: %{not: :a_struct}}
  end

  defp configure(upcasters) do
    Application.put_env(:eventstore_sqlite, :upcasters, upcasters)
    on_exit(fn -> Application.delete_env(:eventstore_sqlite, :upcasters) end)
  end

  describe "without upcasters" do
    test "events are read as stored" do
      :ok = EventstoreSqlite.append_to_stream("s", [%OldScanned{ticket_id: "t1"}])

      assert [%RecordedEvent{data: %OldScanned{ticket_id: "t1"}, type: "Elixir.EventstoreSqlite.UpcasterTest.OldScanned"}] =
               EventstoreSqlite.read_stream_forward("s")
    end
  end

  describe "rename/2" do
    test "renames the event's module and recomputes its type" do
      configure([RenameUpcaster])
      :ok = EventstoreSqlite.append_to_stream("s", [%OldScanned{ticket_id: "t1"}])

      assert [%RecordedEvent{data: data, type: "Elixir.EventstoreSqlite.UpcasterTest.Scanned"}] =
               EventstoreSqlite.read_stream_forward("s")

      assert data.__struct__ == Scanned
      assert data.ticket_id == "t1"
      refute Map.has_key?(data, :gate)
    end

    test "renames structs nested in data and metadata" do
      configure([RenameUpcaster])

      :ok =
        EventstoreSqlite.append_to_stream("s", [
          %NewEvent{
            data: %OldScanned{ticket_id: "t1", location: [{:at, %{main: %OldLocation{name: "hall"}}}]},
            metadata: %{%OldLocation{name: "key"} => [%OldLocation{name: "value"} | :improper]}
          }
        ])

      assert [%RecordedEvent{data: data, metadata: metadata}] = EventstoreSqlite.read_stream_forward("s")
      assert [{:at, %{main: %Location{name: "hall"}}}] = data.location
      assert %{%Location{name: "key"} => [%Location{name: "value"} | :improper]} == metadata
    end

    test "leaves structs it has no rename for alone" do
      configure([RenameUpcaster])
      created_at = ~U[2026-10-02 10:00:00Z]

      :ok =
        EventstoreSqlite.append_to_stream("s", [
          %NewEvent{data: %Untouched{text: "x"}, metadata: %{at: created_at}}
        ])

      assert [%RecordedEvent{data: %Untouched{text: "x"}, metadata: %{at: ^created_at}}] =
               EventstoreSqlite.read_stream_forward("s")
    end

    test "returns the event unchanged for an empty rename map" do
      event = %RecordedEvent{
        id: Ecto.UUID.generate(),
        data: %OldScanned{ticket_id: "t1"},
        type: "Elixir.EventstoreSqlite.UpcasterTest.OldScanned",
        stream_id: "s",
        stream_version: 0,
        created_at: ~U[2026-10-02 10:00:00Z]
      }

      assert Upcaster.rename(event, %{}) == event
    end
  end

  describe "configured upcasters" do
    test "run in order, each seeing the previous one's output" do
      configure([RenameUpcaster, GateUpcaster])
      :ok = EventstoreSqlite.append_to_stream("s", [%OldScanned{ticket_id: "t1", location: %OldLocation{name: "hall"}}])

      assert [%RecordedEvent{data: %Scanned{ticket_id: "t1", gate: :unknown, location: %Location{name: "hall"}}}] =
               EventstoreSqlite.read_stream_forward("s")
    end

    test "apply to backward, multi-stream and $all reads" do
      configure([RenameUpcaster, GateUpcaster])
      :ok = EventstoreSqlite.append_to_stream("a", [%OldScanned{ticket_id: "t1"}])
      :ok = EventstoreSqlite.append_to_stream("b", [%OldScanned{ticket_id: "t2"}])

      for events <- [
            EventstoreSqlite.read_stream_backward("a"),
            EventstoreSqlite.read_stream_forward(["a", "b"]),
            EventstoreSqlite.read_stream_forward("$all")
          ],
          event <- events do
        assert %Scanned{gate: :unknown} = event.data
      end
    end

    test "apply to events delivered to subscribers" do
      configure([RenameUpcaster, GateUpcaster])
      :ok = EventstoreSqlite.append_to_stream("s", [%OldScanned{ticket_id: "t1"}])

      :ok = EventstoreSqlite.subscribe_to_stream(self(), "s", 0)
      assert_receive {:events, [%RecordedEvent{data: %Scanned{ticket_id: "t1", gate: :unknown}}]}

      :ok = EventstoreSqlite.append_to_stream("s", [%OldScanned{ticket_id: "t2"}])
      assert_receive {:events, [%RecordedEvent{data: %Scanned{ticket_id: "t2", gate: :unknown}}]}
    end

    test "keep only data and metadata from an upcaster, and derive type from data" do
      :ok = EventstoreSqlite.append_to_stream("s", [%Untouched{text: "x"}])
      [stored] = EventstoreSqlite.read_stream_forward("s")

      configure([EnvelopeUpcaster])
      [upcasted] = EventstoreSqlite.read_stream_forward("s")

      assert upcasted == %{stored | metadata: %{upcasted: true}}
    end

    test "raise when an upcaster returns data that is not a struct" do
      configure([BrokenUpcaster])
      :ok = EventstoreSqlite.append_to_stream("s", [%Untouched{text: "x"}])

      assert_raise ArgumentError, ~r/BrokenUpcaster must return a RecordedEvent/, fn ->
        EventstoreSqlite.read_stream_forward("s")
      end
    end
  end
end
