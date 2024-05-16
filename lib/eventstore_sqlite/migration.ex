defmodule EventstoreSqlite.Migration do
  @all_stream_id "$all"

  def intial_fill_all() do
    {:ok, _} =
      Ecto.Multi.new()
      |> delete_all()
      |> fill_all()
      |> update_streams()
      |> EventstoreSqlite.RepoWrite.transaction()
  end

  defp delete_all(multi) do
    Ecto.Multi.run(multi, :delete_all, fn repo, _ ->
      query = ~s"""
      DELETE FROM stream_events WHERE stream_id == '#{@all_stream_id}';
      """

      Ecto.Adapters.SQL.query(repo, query)
    end)
  end

  defp fill_all(multi) do
    Ecto.Multi.run(multi, :fill_all, fn repo, _ ->
      query = ~s"""
      WITH stream_events_not_all (id, event_id, stream_id, stream_version)
      AS (select id, event_id, stream_id, stream_version from stream_events where stream_id <> '#{@all_stream_id}')
      INSERT INTO stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version)
      SELECT
        stream_events_not_all.event_id, '#{@all_stream_id}', stream_events_not_all.id, stream_events_not_all.stream_id, stream_events_not_all.stream_version
      FROM stream_events_not_all ORDER BY event_id
      RETURNING 1
      """

      Ecto.Adapters.SQL.query(repo, query)
    end)
  end

  defp update_streams(multi) do
    Ecto.Multi.run(multi, :update_streams, fn repo, _ ->
      query = ~s"""
      UPDATE streams SET stream_version = (select max(stream_version) from stream_events where stream_id='$all')
      where stream_id = '$all'
      """

      Ecto.Adapters.SQL.query(repo, query)
    end)
  end
end
