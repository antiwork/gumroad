# frozen_string_literal: true

require "test_helper"

class PreorderHelperTest < ActionView::TestCase
  SELLER_TIMEZONE = "Pacific Time (US & Canada)"

  test "displayable_release_at_date returns the date in the seller's timezone" do
    release_at = DateTime.parse("Aug 3rd 2018 11AM")
    assert_equal "August 3, 2018", displayable_release_at_date(release_at, SELLER_TIMEZONE)
  end

  test "displayable_release_at_date returns the previous day when the timezone shifts the date" do
    # Aug 3rd at 3AM UTC is actually Aug 2nd in PDT
    release_at = DateTime.parse("Aug 3rd 2018 3AM")
    assert_equal "August 2, 2018", displayable_release_at_date(release_at, SELLER_TIMEZONE)
  end

  test "displayable_release_at_time returns the time in the seller's timezone" do
    # 11AM UTC is 4AM PDT; the leading space is the result of the %l format string
    release_at = DateTime.parse("Aug 3rd 2018 11AM")
    assert_equal " 4AM", displayable_release_at_time(release_at, SELLER_TIMEZONE)
  end

  test "displayable_release_at_time accounts for PST in winter" do
    # 7AM UTC is 11PM PST
    release_at = DateTime.parse("Dec 3rd 2018 7AM")
    assert_equal "11PM", displayable_release_at_time(release_at, SELLER_TIMEZONE)
  end

  test "displayable_release_at_date_and_time formats date and time in the seller's timezone" do
    release_at = DateTime.parse("Dec 3rd 2018 7AM")
    assert_equal "December 2nd, 11PM PST", displayable_release_at_date_and_time(release_at, SELLER_TIMEZONE)
  end

  test "displayable_release_at_date_and_time accounts for DST" do
    release_at = DateTime.parse("Aug 3rd 2018 5AM")
    assert_equal "August 2nd, 10PM PDT", displayable_release_at_date_and_time(release_at, SELLER_TIMEZONE)
  end

  test "displayable_release_at_date_and_time includes the minute when not zero" do
    release_at = DateTime.parse("Dec 3rd 2018 7:12AM")
    assert_equal "December 2nd, 11:12PM PST", displayable_release_at_date_and_time(release_at, SELLER_TIMEZONE)
  end

  test "displayable_release_at_time includes the minute when not zero" do
    release_at = DateTime.parse("Dec 3rd 2018 7:12AM")
    assert_equal "11:12PM", displayable_release_at_time(release_at, SELLER_TIMEZONE)
  end
end
