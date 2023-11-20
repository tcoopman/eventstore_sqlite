defmodule EventstoreSqlite.Event do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, []}
  schema "events" do
    field :type, :string
    field :data, :map
    field :metadata, :map

    timestamps(updated_at: false, type: :utc_datetime)
  end

  def new(event) do
    date = DateTime.utc_now() |> DateTime.truncate(:second)

    data = %{
      id: Uniq.UUID.uuid7(),
      data: Map.delete(event, :__struct__),
      type: event.__struct__ |> Atom.to_string(),
      inserted_at: date
    }

    changeset(%__MODULE__{}, data) |> apply_action!(:insert)
  end

  @doc false
  def changeset(event, attrs) do
    event
    |> cast(attrs, [:id, :type, :data, :metadata, :inserted_at])
    |> validate_required([:id, :data, :type, :inserted_at])
  end
end
