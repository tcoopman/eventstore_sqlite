defmodule EventstoreSqlite.Event do
  @moduledoc false
  use Ecto.Schema

  import Ecto.Changeset

  alias EventstoreSqlite.NewEvent

  @primary_key {:id, :binary_id, []}
  schema "events" do
    field(:type, :string)
    field(:data, :binary)
    field(:metadata, :binary)

    timestamps(updated_at: false, type: :utc_datetime)
  end

  def new(%NewEvent{} = new_event) do
    build(new_event.id, new_event.data, new_event.metadata)
  end

  def new(event), do: build(nil, event, %{})

  defp build(id, event, metadata) when is_map(metadata) do
    date = DateTime.truncate(DateTime.utc_now(), :second)

    data = %{
      id: event_id(id),
      data: :erlang.term_to_binary(event),
      metadata: encode_metadata(metadata),
      type: Atom.to_string(event.__struct__),
      inserted_at: date
    }

    %__MODULE__{} |> changeset(data) |> apply_action!(:insert)
  end

  defp event_id(nil), do: Uniq.UUID.uuid7()

  defp event_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> uuid
      :error -> raise ArgumentError, "expected a UUID as the event id, got: #{inspect(id)}"
    end
  end

  defp encode_metadata(metadata) when map_size(metadata) == 0, do: nil
  defp encode_metadata(metadata), do: :erlang.term_to_binary(metadata)

  @doc false
  def changeset(event, attrs) do
    event
    |> cast(attrs, [:id, :type, :data, :metadata, :inserted_at])
    |> validate_required([:id, :data, :type, :inserted_at])
  end
end
