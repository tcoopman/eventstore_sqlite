defmodule EventstoreSqliteTest do
  use ExUnit.Case
  doctest EventstoreSqlite

  test "greets the world" do
    assert EventstoreSqlite.hello() == :world
  end
end
