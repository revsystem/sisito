require "test_helper"

class StatsControllerTest < ActionDispatch::IntegrationTest
  test "reflects the given date range in the aggregation blocks" do
    get root_path, params: { from: "2026-08-01", to: "2026-08-02" }

    assert_response :success
    assert_includes response.body, "2026-08-01 〜 2026-08-02"
    assert_includes response.body, "test1.example.com"
    assert_includes response.body, "test2.example.com"
    assert_not_includes response.body, "excluded-before.example.com"
    assert_not_includes response.body, "excluded-after.example.com"
  end

  test "shows No data in this period for a range with no bounces" do
    get root_path, params: { from: "2020-01-01", to: "2020-01-02" }

    assert_response :success
    assert_includes response.body, "No data in this period."
  end
end
