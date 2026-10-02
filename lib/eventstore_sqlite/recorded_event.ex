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
    field(:original_stream_id, :string, default: nil)
    field(:original_stream_version, :number, default: nil)
  end

  def parse(row) do
    %EventstoreSqlite.RecordedEvent{
      id: row.id,
      data: :erlang.binary_to_term(row.data),
      stream_id: row.stream_id,
      stream_version: row.stream_version,
      original_stream_id: row.original_stream_id,
      original_stream_version: row.original_stream_version,
      type: row.type,
      created_at: row.created_at,
      metadata: decode_metadata(row.metadata)
    }
  end

  defp decode_metadata(nil), do: %{}
  defp decode_metadata("null"), do: %{}
  defp decode_metadata(metadata), do: :erlang.binary_to_term(metadata)
end
