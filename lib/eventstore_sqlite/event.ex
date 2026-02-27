defmodule EventstoreSqlite.Event do
  @moduledoc false
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, []}
  schema "events" do
    field(:type, :string)
    field(:data, :binary)
    field(:metadata, :map)

    timestamps(updated_at: false, type: :utc_datetime)
  end

  def new(event) do
    date = DateTime.truncate(DateTime.utc_now(), :second)

    data = %{
      id: Uniq.UUID.uuid7(),
      data: :erlang.term_to_binary(event),
      type: Atom.to_string(event.__struct__),
      inserted_at: date
    }

    %__MODULE__{} |> changeset(data) |> apply_action!(:insert)
  end

  @doc false
  def changeset(event, attrs) do
    event
    |> cast(attrs, [:id, :type, :data, :metadata, :inserted_at])
    |> validate_required([:id, :data, :type, :inserted_at])
  end
end
