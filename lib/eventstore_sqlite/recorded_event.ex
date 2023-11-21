defmodule EventstoreSqlite.RecordedEvent do
  use TypedStruct

  typedstruct enforce: true do
    field(:id, Ecto.UUID.t())
    field(:data, :any)
    field(:type, :string)
    field(:stream_id, :string)
    field(:created_at, :date)
  end

  def parse(id, type, stream_id, data, created) do
    event = :erlang.binary_to_term(data)

    %EventstoreSqlite.RecordedEvent{
      id: id,
      data: event,
      stream_id: stream_id,
      type: type,
      created_at: created
    }
  end
end
