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
    field(:metadata, :map, default: %{})
  end

  def parse(row) do
    %EventstoreSqlite.RecordedEvent{
      id: row.id,
      data: :erlang.binary_to_term(row.data),
      stream_id: row.stream_id,
      stream_version: row.stream_version,
      type: row.type,
      created_at: row.created_at,
      metadata: decode_metadata(row.metadata)
    }
  end

  defp decode_metadata(nil), do: %{}
  defp decode_metadata(metadata), do: :erlang.binary_to_term(metadata)
end
