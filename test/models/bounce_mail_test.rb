require "test_helper"

class BounceMailTest < ActiveSupport::TestCase
  test "within_period includes the start of the range at 00:00:00" do
    result = BounceMail.within_period(Date.parse("2026-08-01"), Date.parse("2026-08-02"))
    assert_includes result, bounce_mails(:boundary_start)
  end

  test "within_period includes the end of the range at 23:59:59" do
    result = BounceMail.within_period(Date.parse("2026-08-01"), Date.parse("2026-08-02"))
    assert_includes result, bounce_mails(:boundary_end)
  end

  test "within_period excludes the day before the range" do
    result = BounceMail.within_period(Date.parse("2026-08-01"), Date.parse("2026-08-02"))
    assert_not_includes result, bounce_mails(:day_before_start)
  end

  test "within_period excludes the day after the range" do
    result = BounceMail.within_period(Date.parse("2026-08-01"), Date.parse("2026-08-02"))
    assert_not_includes result, bounce_mails(:boundary_next_day)
  end
end
