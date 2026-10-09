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

  defmodule SyncEnabled do
    @moduledoc """
    Appended to `"$sync"` by `EventstoreSqlite.Sync.enable/1`. The node becomes
    the home node of a new replication group named by `sync_id`.
    """
    use TypedStruct

    typedstruct enforce: true do
      field(:node_id, String.t())
      field(:home, String.t())
      field(:sync_id, String.t())
    end
  end

  defmodule SyncDisabled do
    @moduledoc """
    Appended to `"$sync"` by `EventstoreSqlite.Sync.disable/0`.
    """
    defstruct []
  end

  defmodule PeerAdded do
    @moduledoc """
    Appended to `"$sync"` when the home node provisions a peer with
    `EventstoreSqlite.Sync.snapshot/2`. `pinned_seq` is the log head at that
    moment; the log isn't pruned past it until the peer has acknowledged it.
    """
    use TypedStruct

    typedstruct enforce: true do
      field(:node_id, String.t())
      field(:pinned_seq, non_neg_integer())
    end
  end

  defmodule PeerRemoved do
    @moduledoc """
    Appended to `"$sync"` by `EventstoreSqlite.Sync.remove_peer/2`.
    `discarded_after` is set when unpulled entries of the peer were discarded:
    everything it wrote after that seq is lost.
    """
    use TypedStruct

    typedstruct do
      field(:node_id, String.t(), enforce: true)
      field(:discarded_after, non_neg_integer() | nil)
    end
  end

  defmodule SnapshotCreated do
    @moduledoc """
    Written only into a snapshot copy by `EventstoreSqlite.Sync.snapshot/2`. A
    store whose latest `"$sync"` event is this one may be claimed once, by the
    node named `for_node`.
    """
    use TypedStruct

    typedstruct enforce: true do
      field(:snapshot_id, String.t())
      field(:for_node, String.t())
      field(:snapshot_of, String.t())
      field(:head_seq, non_neg_integer())
    end
  end

  defmodule SnapshotClaimed do
    @moduledoc """
    Appended to `"$sync"` when a node boots on a snapshot made for it. The node
    takes `node_id` as its identity and continues from `cursor` in the log of
    `snapshot_of`.
    """
    use TypedStruct

    typedstruct enforce: true do
      field(:snapshot_id, String.t())
      field(:node_id, String.t())
      field(:snapshot_of, String.t())
      field(:cursor, non_neg_integer())
    end
  end

  defmodule SyncHalted do
    @moduledoc """
    Appended to `"$sync"` when replication from `peer` stops because of
    `reason`. Cleared by `EventstoreSqlite.Sync.resume/1`.
    """
    use TypedStruct

    typedstruct enforce: true do
      field(:peer, String.t())
      field(:reason, term())
    end
  end

  defmodule SyncResumed do
    @moduledoc """
    Appended to `"$sync"` by `EventstoreSqlite.Sync.resume/1`.
    """
    use TypedStruct

    typedstruct enforce: true do
      field(:peer, String.t())
    end
  end

  defmodule NodeDiverged do
    @moduledoc """
    Appended to `"$sync"` on a node that imported its own forced revocation.
    The node refuses every write from then on; it has to be rebuilt from a new
    snapshot under a new node id.
    """
    use TypedStruct

    typedstruct enforce: true do
      field(:node_id, String.t())
      field(:revoked_by, String.t())
      field(:revoke_seq, pos_integer())
    end
  end

  defmodule OwnershipAssigned do
    @moduledoc """
    Appended to `"$ownership"` when the home node assigns the streams matching
    `selector` to `to`. `generation` identifies this assignment.
    """
    use TypedStruct

    typedstruct enforce: true do
      field(:selector, String.t())
      field(:to, String.t())
      field(:generation, pos_integer())
    end
  end

  defmodule OwnershipReleased do
    @moduledoc """
    Appended to `"$ownership"` when the owner of `generation` hands it back to
    the home node. `release_seq` is the owner's log seq of the release.
    """
    use TypedStruct

    typedstruct enforce: true do
      field(:generation, pos_integer())
      field(:from, String.t())
      field(:release_seq, pos_integer())
    end
  end

  defmodule ReleaseIgnored do
    @moduledoc """
    Appended to `"$ownership"` when a release arrives for a generation that is
    no longer active, so it changes nothing.
    """
    use TypedStruct

    typedstruct enforce: true do
      field(:generation, pos_integer())
      field(:from, String.t())
    end
  end

  defmodule OwnershipRevoked do
    @moduledoc """
    Appended to `"$ownership"` for each generation a forced reclaim
    (`EventstoreSqlite.Ownership.revoke_node/1`) takes back. Entries of `from`
    carrying this generation that arrive later are quarantined. `cutoff` is the
    home node's cursor in the log of `from` at that moment.
    """
    use TypedStruct

    typedstruct enforce: true do
      field(:generation, pos_integer())
      field(:selector, String.t())
      field(:from, String.t())
      field(:cutoff, non_neg_integer())
    end
  end

  defmodule NodeRetired do
    @moduledoc """
    Appended to `"$ownership"` by a forced reclaim. `node_id` can never own
    streams again. `revoke_seq` is the home node's log seq of the revocation.
    """
    use TypedStruct

    typedstruct enforce: true do
      field(:node_id, String.t())
      field(:revoke_seq, pos_integer())
    end
  end
end
