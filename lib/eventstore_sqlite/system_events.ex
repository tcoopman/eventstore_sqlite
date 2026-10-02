defmodule EventstoreSqlite.SystemEvents do
  @moduledoc """
  Events written by eventstore_sqlite itself.

  An event's stored type is its module name, so this namespace keeps system
  events apart from an application's own events. Don't define modules under
  `EventstoreSqlite.SystemEvents` in your own code.

  System events are stored with `:erlang.term_to_binary/1`. Their structs only
  ever gain fields, so an event written by an older version can lack a field a
  newer version defines.
  """

  defmodule StreamArchived do
    @moduledoc """
    Appended to `"$archives"` when `EventstoreSqlite.archive_stream/2` archives a
    stream.

      * `stream_id` - the archived stream.
      * `archive_id` - identifies this archive; a stream name can be archived,
        reused and archived again.
      * `event_count` - the number of archived events, which is also the version
        the stream's next event would have had. The archived events are versions
        `0..event_count - 1`.
    """
    use TypedStruct

    typedstruct enforce: true do
      field(:stream_id, String.t())
      field(:archive_id, pos_integer())
      field(:event_count, non_neg_integer())
    end
  end
end
