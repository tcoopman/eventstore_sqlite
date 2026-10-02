defmodule EventstoreSqlite.Upcaster do
  @moduledoc """
  Upcasts stored events to their current shape as they are read.

  Events are stored with `:erlang.term_to_binary/1`, so a stored event keeps the
  shape it was written in: its struct's module name, and only the fields that
  struct had at the time. An upcaster turns such an event into the shape the
  application expects today. Stored events are never changed.

  Configure upcasters as a list of modules implementing this behaviour:

      config :eventstore_sqlite, upcasters: [MyApp.EventUpcaster]

  Every event handed out by a read (`EventstoreSqlite.stream_forward/2` and
  friends) or a subscription (`EventstoreSqlite.subscribe_to_stream/5`) passes
  through the upcasters in list order, so a later upcaster sees the output of
  an earlier one. The configuration is read at the start of every chunk of a
  read.

  An upcaster receives the whole `EventstoreSqlite.RecordedEvent`, so it can
  decide by `created_at`, `metadata` or the stream an event belongs to. Only the
  `data` and `metadata` of the returned event are kept; the event's id, stream,
  versions and creation time cannot be changed. `type` is set to the module of
  the returned `data`, so it always agrees with it.

  An upcaster must return every event it does not recognise unchanged,
  including the library's own `EventstoreSqlite.SystemEvents`. An exception
  raised by an upcaster fails the read, or crashes the subscription process.

  ## Example

      defmodule MyApp.EventUpcaster do
        @behaviour EventstoreSqlite.Upcaster

        alias EventstoreSqlite.RecordedEvent

        @renamed %{MyApp.TicketScanned => MyApp.Scanning.TicketScanned}

        @impl true
        def upcast(%RecordedEvent{} = event) do
          event
          |> EventstoreSqlite.Upcaster.rename(@renamed)
          |> add_gate()
        end

        defp add_gate(%RecordedEvent{data: %{__struct__: MyApp.Scanning.TicketScanned} = data} = event)
             when not is_map_key(data, :gate) do
          %{event | data: Map.put(data, :gate, :unknown)}
        end

        defp add_gate(event), do: event
      end

  A struct decoded from an older event lacks the fields its module gained since,
  so match it through a plain `%{__struct__: Module}` map: with `%Module{}` the
  compiler assumes every field is present.
  """

  alias EventstoreSqlite.RecordedEvent

  @callback upcast(RecordedEvent.t()) :: RecordedEvent.t()

  @doc """
  Renames struct modules everywhere in an event's `data` and `metadata`.

  `renames` maps the module a struct was stored under to its current module,
  e.g. `%{MyApp.TicketScanned => MyApp.Scanning.TicketScanned}`. Structs nested
  in maps, lists and tuples are renamed too. Only the module changes; the
  struct's fields are kept as stored.
  """
  @spec rename(RecordedEvent.t(), %{module() => module()}) :: RecordedEvent.t()
  def rename(%RecordedEvent{} = event, renames) when map_size(renames) == 0, do: event

  def rename(%RecordedEvent{} = event, renames) when is_map(renames) do
    %{event | data: rename_term(event.data, renames), metadata: rename_term(event.metadata, renames)}
  end

  defp rename_term(%{__struct__: module} = struct, renames) when is_atom(module) do
    struct
    |> Map.delete(:__struct__)
    |> rename_term(renames)
    |> Map.put(:__struct__, Map.get(renames, module, module))
  end

  defp rename_term(map, renames) when is_map(map) do
    Map.new(map, fn {key, value} -> {rename_term(key, renames), rename_term(value, renames)} end)
  end

  defp rename_term([head | tail], renames), do: [rename_term(head, renames) | rename_term(tail, renames)]

  defp rename_term(tuple, renames) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> rename_term(renames) |> List.to_tuple()
  end

  defp rename_term(term, _renames), do: term

  @doc false
  def upcasters, do: Application.get_env(:eventstore_sqlite, :upcasters, [])

  @doc false
  def apply_all(%RecordedEvent{} = event, []), do: event

  def apply_all(%RecordedEvent{} = event, upcasters) do
    upcasted = Enum.reduce(upcasters, event, &apply_one/2)
    %{event | data: upcasted.data, metadata: upcasted.metadata, type: Atom.to_string(upcasted.data.__struct__)}
  end

  defp apply_one(upcaster, event) do
    case upcaster.upcast(event) do
      %RecordedEvent{data: %{__struct__: module}, metadata: metadata} = upcasted
      when is_atom(module) and is_map(metadata) ->
        upcasted

      other ->
        raise ArgumentError,
              "upcaster #{inspect(upcaster)} must return a RecordedEvent whose data is a struct " <>
                "and whose metadata is a map, got: #{inspect(other)}"
    end
  end
end
