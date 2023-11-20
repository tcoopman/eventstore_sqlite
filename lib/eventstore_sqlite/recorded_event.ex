defmodule EventstoreSqlite.RecordedEvent do
  use TypedStruct

  typedstruct do
    field :event_uuid, Ecto.UUID.t()
    field :data, :any
  end

  def parse(uuid, type, data) do
    event_type = type |> String.to_existing_atom()

    keys =
      struct(event_type)
      |> Map.keys()
      |> Enum.filter(fn
        :__struct__ -> false
        _ -> true
      end)

    map =
      Enum.reduce(keys, %{}, fn key, acc ->
        Map.put(acc, key, data[Atom.to_string(key)])
      end)

    data = struct!(event_type, map)

    %EventstoreSqlite.RecordedEvent{
      event_uuid: uuid,
      data: data
    }
  end
end
