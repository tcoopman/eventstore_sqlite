defmodule EventstoreSqlite.LiveEventstore.Payload do
  @moduledoc false

  alias EventstoreSqlite.RecordedEvent

  @iso8601 [DateTime, NaiveDateTime, Date, Time]

  @doc """
  The whole recorded event as pretty-printed JSON: its envelope, metadata and
  data.
  """
  def event_json(%RecordedEvent{} = event) do
    Jason.encode!(
      Jason.OrderedObject.new(
        id: event.id,
        type: event.type,
        stream_id: event.stream_id,
        stream_version: event.stream_version,
        original_stream_id: event.original_stream_id,
        original_stream_version: event.original_stream_version,
        created_at: to_json(event.created_at),
        metadata: to_json(event.metadata),
        data: data_to_json(event.data)
      ),
      pretty: true
    )
  end

  @doc """
  `term` as pretty-printed JSON. Terms JSON has no notation for are written
  as close as JSON allows: tuples become arrays, atoms strings, dates ISO 8601
  strings, structs objects with a `"__struct__"` key, and binaries that aren't
  UTF-8 `{"__binary__": base64}`. Anything else is written as `inspect/1`
  would show it.
  """
  def json(term), do: Jason.encode!(to_json(term), pretty: true)

  @doc """
  An event's data as pretty-printed JSON. Its struct isn't named: the event's
  type already does.
  """
  def data_json(data), do: Jason.encode!(data_to_json(data), pretty: true)

  defp data_to_json(%_{} = data), do: data |> Map.from_struct() |> to_json()
  defp data_to_json(data), do: to_json(data)

  defp to_json(term) when is_nil(term) or is_boolean(term) or is_number(term), do: term
  defp to_json(atom) when is_atom(atom), do: atom_name(atom)

  defp to_json(binary) when is_binary(binary) do
    if String.valid?(binary), do: binary, else: %{"__binary__" => Base.encode64(binary)}
  end

  defp to_json(%module{} = struct) when module in @iso8601, do: module.to_iso8601(struct)

  defp to_json(%module{} = struct) do
    if String.Chars.impl_for(struct) do
      to_string(struct)
    else
      struct
      |> Map.from_struct()
      |> to_json()
      |> Map.put("__struct__", inspect(module))
    end
  end

  defp to_json(map) when is_map(map), do: Map.new(map, fn {key, value} -> {key_name(key), to_json(value)} end)

  defp to_json(list) when is_list(list) do
    if proper_list?(list), do: Enum.map(list, &to_json/1), else: inspect(list)
  end

  defp to_json(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> Enum.map(&to_json/1)
  defp to_json(other), do: inspect(other)

  defp atom_name(atom) do
    name = Atom.to_string(atom)
    if String.starts_with?(name, "Elixir."), do: inspect(atom), else: name
  end

  defp key_name(key) when is_binary(key), do: key
  defp key_name(key) when is_atom(key), do: atom_name(key)
  defp key_name(key), do: inspect(key)

  defp proper_list?([]), do: true
  defp proper_list?([_ | tail]), do: proper_list?(tail)
  defp proper_list?(_improper), do: false
end
