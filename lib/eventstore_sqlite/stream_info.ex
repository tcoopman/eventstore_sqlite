defmodule EventstoreSqlite.StreamInfo do
  @moduledoc """
  What the store knows about a live stream, without reading its events.

  Returned by `EventstoreSqlite.stream_info/1` and
  `EventstoreSqlite.list_stream_infos/1`.

    * `stream_id` — the stream's name;
    * `version` — the stream's current version: the next version to be
      appended, which is also its event count. It is the `n` that
      `{:version, n}` expects in `EventstoreSqlite.append_to_stream/3`;
    * `created_at` — when the stream's first event was appended. After an
      archive, a new stream with the same name has its own `created_at`;
    * `last_event_at` — when its last event was appended;
    * `owner` — with sync enabled, the node allowed to write the stream and
      the ownership generation that allows it, as
      `EventstoreSqlite.Ownership.owner/1` returns it. `nil` with sync
      disabled, and for system streams.

  Timestamps are the events' own, truncated to the second, so they are the
  same on every node of a sync group. They are `nil` only for a system stream
  whose events were all archived.
  """
  use TypedStruct

  typedstruct enforce: true do
    field(:stream_id, String.t())
    field(:version, non_neg_integer())
    field(:created_at, DateTime.t() | nil)
    field(:last_event_at, DateTime.t() | nil)
    field(:owner, {String.t(), non_neg_integer()} | nil)
  end
end
