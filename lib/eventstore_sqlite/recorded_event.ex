defmodule EventstoreSqlite.RecordedEvent do
  use TypedStruct

  typedstruct do
    field(:id, Ecto.UUID.t())
    field(:data, :any)
    field(:type, :string)
  end

  def parse(id, type, data) do
    event = :erlang.binary_to_term(data)

    %EventstoreSqlite.RecordedEvent{
      id: id,
      data: event,
      type: type
    }
  end
end
