require "test_helper"

class StatsHelperTest < ActionView::TestCase
  test "returns individual slices without an etc entry when nothing remains" do
    assert_equal [["a", 5], ["b", 3], ["c", 1]], chart_columns({"a" => 5, "b" => 3, "c" => 1})
  end

  test "adds an etc entry summing everything past top" do
    columns = chart_columns({"a" => 5, "b" => 3, "c" => 1, "d" => 1})
    assert_equal [["a", 5], ["b", 3], ["c", 1], ["etc", 1]], columns
  end

  test "does not add an etc entry for fewer than top elements" do
    assert_equal [["a", 5], ["b", 3]], chart_columns({"a" => 5, "b" => 3})
  end

  test "does not add an etc entry for an empty collection" do
    assert_equal [], chart_columns({})
  end

  test "accepts an already-sorted array of pairs without mutating it" do
    pairs = [["a", 5], ["b", 3], ["c", 1], ["d", 1]]
    original = pairs.dup
    chart_columns(pairs)
    assert_equal original, pairs
  end

  test "respects a custom top" do
    columns = chart_columns({"a" => 4, "b" => 3, "c" => 2, "d" => 1}, top: 2)
    assert_equal [["a", 4], ["b", 3], ["etc", 3]], columns
  end
end
