defmodule EventstoreSqlite.RecordedEvent do
  @moduledoc """
  An event as read back from the store.

  Reads (`EventstoreSqlite.stream_forward/2` and friends) and subscriptions
  (`EventstoreSqlite.subscribe_to_stream/5`) return these structs.

    * `id` — the event's UUID string;
    * `data` — the decoded event struct;
    * `type` — the event struct's module name as a string;
    * `created_at` — when the event was appended, as a `DateTime` truncated to
      the second;
    * `metadata` — the decoded metadata map, or `%{}` when none was stored;
    * `stream_id` and `stream_version` — the stream that was read, and the
      event's version in it;
    * `original_stream_id` and `original_stream_version` — the stream the
      event was appended to, and its version there.

  For an application stream the `original_*` fields equal `stream_id` and
  `stream_version`. For an event read from `"$all"`, `stream_id` is `"$all"`
  and `stream_version` is the event's position in `"$all"`, while the
  `original_*` fields name the application stream and the event's version in
  it. Save `stream_version` as a subscriber's checkpoint; use the `original_*`
  fields to tell which stream an `"$all"` event belongs to.

  Versions and positions are zero-based. `"$all"` positions can have gaps after
  an archive (see `EventstoreSqlite.archive_stream/2`).

  The `original_*` fields are `nil` only in structs built by hand.
  """
  use TypedStruct

  typedstruct enforce: true do
    field(:id, Ecto.UUID.t())
    field(:data, struct())
    field(:type, String.t())
    field(:stream_id, String.t())
    field(:stream_version, non_neg_integer())
    field(:created_at, DateTime.t())
    field(:metadata, map(), default: %{})
    field(:original_stream_id, String.t() | nil, default: nil)
    field(:original_stream_version, non_neg_integer() | nil, default: nil)
  end

  @doc false
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
