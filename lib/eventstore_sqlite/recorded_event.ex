defmodule EventstoreSqlite.RecordedEvent do
  @moduledoc false
  use TypedStruct

  typedstruct enforce: true do
    field(:id, Ecto.UUID.t())
    field(:data, :any)
    field(:type, :string)
    field(:stream_id, :string)
    field(:stream_version, :number)
    field(:created_at, :date)
  end

  def parse(id, type, stream_id, data, created, stream_version) do
    event = :erlang.binary_to_term(data)

    %EventstoreSqlite.RecordedEvent{
      id: id,
      data: event,
      stream_id: stream_id,
      stream_version: stream_version,
      type: type,
      created_at: created
    }
  end
end
