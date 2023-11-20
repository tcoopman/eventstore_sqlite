defmodule EventstoreSqlite.Stream do
  use Ecto.Schema
  import Ecto.Changeset

  schema "streams" do
    field :stream_id, :string
    field :stream_version, :integer

    timestamps(updated_at: false, type: :utc_datetime)
  end

  @doc false
  def changeset(event, attrs) do
    event
    |> cast(attrs, [:stream_id, :stream_version])
    |> validate_required([:stream_id, :stream_version])
  end
end
