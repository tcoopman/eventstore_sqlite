defmodule EventstoreSqlite.Sync.VerifyTest do
  use ExUnit.Case, async: true

  alias EventstoreSqlite.Sync.Verify

  defp incarnation(first_id, count, archived \\ false, digest \\ nil) do
    %{first_id: first_id, count: count, archived: archived, digest: digest || "#{first_id}:#{count}"}
  end

  defp digests(side, stream, first_id, count) do
    send(self(), {:digest_asked, side, stream})
    "#{first_id}:#{count}"
  end

  defp compare(local, remote, mode \\ :prefix), do: Verify.compare(local, remote, mode, &digests/4)

  test "identical histories" do
    history = %{"a" => [incarnation("e1", 3)]}
    assert compare(history, history) == {:ok, []}
    assert compare(history, history, :strict) == {:ok, []}
  end

  test "a shorter live incarnation with a matching prefix is lag, checked against the longer side's prefix digest" do
    assert compare(%{"a" => [incarnation("e1", 2)]}, %{"a" => [incarnation("e1", 5)]}) == {:ok, [{"a", :local_behind}]}
    assert_received {:digest_asked, :remote, "a"}

    assert compare(%{"a" => [incarnation("e1", 5)]}, %{"a" => [incarnation("e1", 2)]}) == {:ok, [{"a", :remote_behind}]}

    assert {:error, [{"a", :local_behind}]} =
             compare(%{"a" => [incarnation("e1", 2)]}, %{"a" => [incarnation("e1", 5)]}, :strict)
  end

  test "a prefix whose digest differs is a fork" do
    local = %{"a" => [incarnation("e1", 2, false, "different")]}
    assert {:error, [{"a", _}]} = compare(local, %{"a" => [incarnation("e1", 5)]})
  end

  test "a stream missing on one side is lag" do
    assert compare(%{}, %{"a" => [incarnation("e1", 1)]}) == {:ok, [{"a", :local_behind}]}
  end

  test "an archive the other side hasn't applied yet is lag, also with a reused name" do
    behind = %{"a" => [incarnation("e1", 3)]}
    ahead = %{"a" => [incarnation("e1", 3, true), incarnation("e9", 1)]}

    assert compare(behind, ahead) == {:ok, [{"a", :local_behind}]}
    assert compare(%{"a" => [incarnation("e1", 2)]}, ahead) == {:ok, [{"a", :local_behind}]}
  end

  test "an archived incarnation can't be shorter than the other side's, nor followed by a different one" do
    assert {:error, _} = compare(%{"a" => [incarnation("e1", 2, true)]}, %{"a" => [incarnation("e1", 3)]})

    assert {:error, _} =
             compare(%{"a" => [incarnation("e1", 3, true), incarnation("e5", 1)]}, %{
               "a" => [incarnation("e1", 3, true), incarnation("e6", 1)]
             })
  end

  test "different first events are a fork" do
    assert {:error, _} = compare(%{"a" => [incarnation("e1", 1)]}, %{"a" => [incarnation("e2", 1)]})
  end
end
