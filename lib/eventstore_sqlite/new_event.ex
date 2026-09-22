defmodule EventstoreSqlite.NewEvent do
  @moduledoc """
  An event to append, together with its envelope.

  `EventstoreSqlite.append_to_stream/3` accepts a bare event struct or a
  `NewEvent`. Use a `NewEvent` to attach metadata, or to supply the event's id
  yourself so a sibling in the same batch can reference it:

      %EventstoreSqlite.NewEvent{
        id: correlation_id,
        data: %TicketScanned{ticket_id: ticket_id},
        metadata: %{correlation_id: correlation_id, causation_id: nil}
      }

  A `nil` id mints a UUIDv7. Metadata round-trips through
  `:erlang.term_to_binary/1`, so atom keys stay atoms and nested structs survive
  intact.
  """

  use TypedStruct

  typedstruct do
    field(:data, :any, enforce: true)
    field(:id, Ecto.UUID.t())
    field(:metadata, :map, default: %{})
  end
end
