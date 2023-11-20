defmodule EventstoreSqlite.RecordedEvent do
  use TypedStruct

  typedstruct do
    field :id, Ecto.UUID.t()
    field :data, :any
  end

  def parse(id, type, data) do
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
      id: id,
      data: data
    }
  end
end
