defmodule EventstoreSqlite.Sync.SelectorTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias EventstoreSqlite.Sync.Selector

  test "parses exact names and trailing-* prefixes" do
    assert Selector.parse!("venue:1") == {:exact, "venue:1"}
    assert Selector.parse!("venue:*") == {:prefix, "venue:"}
    assert Selector.parse!("*") == {:prefix, ""}
  end

  test "rejects a * anywhere but at the end, empty selectors and system streams" do
    for selector <- ["ven*ue", "*venue", "venue:**", "", "$all", "$sync*"] do
      assert_raise ArgumentError, fn -> Selector.parse!(selector) end
    end
  end

  test "matches" do
    assert Selector.matches?("venue:*", "venue:1")
    assert Selector.matches?("venue:*", "venue:")
    refute Selector.matches?("venue:*", "venue")
    assert Selector.matches?("venue:1", "venue:1")
    refute Selector.matches?("venue:1", "venue:10")
  end

  test "overlap" do
    assert Selector.overlap?("venue:*", "venue:vip")
    assert Selector.overlap?("venue:vip", "venue:*")
    assert Selector.overlap?("venue:*", "venue:vip:*")
    assert Selector.overlap?("venue:*", "venue:*")
    assert Selector.overlap?("a", "a")
    refute Selector.overlap?("venue:*", "orders:*")
    refute Selector.overlap?("venue:1", "venue:2")
    refute Selector.overlap?("venue:a*", "venue:b*")
  end

  defp selector do
    gen_result =
      gen all(name <- string([?a, ?b, ?:], max_length: 4), prefix? <- boolean()) do
        if prefix?, do: name <> "*", else: name
      end

    filter(gen_result, &(&1 != ""))
  end

  property "two selectors overlap exactly when some stream matches both" do
    check all(a <- selector(), b <- selector()) do
      candidates =
        for x <- [a, b], suffix <- ["", "a", "b", ":", "ab"] do
          String.trim_trailing(x, "*") <> suffix
        end

      some_stream_matches_both = Enum.any?(candidates, &(Selector.matches?(a, &1) and Selector.matches?(b, &1)))
      assert Selector.overlap?(a, b) == some_stream_matches_both
      assert Selector.overlap?(a, b) == Selector.overlap?(b, a)
    end
  end
end
