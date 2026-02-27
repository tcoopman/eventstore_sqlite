defmodule EventstoreSqlite.RepoWrite do
  @moduledoc false
  use Ecto.Repo,
    otp_app: :eventstore_sqlite,
    adapter: Ecto.Adapters.SQLite3
end
