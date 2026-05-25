# frozen_string_literal: true

require "test_helper"

class D3Test < ActiveSupport::TestCase
  test "formatted_date returns 'Today' when the date is today" do
    today = Date.new(2020, 6, 15)
    assert_equal "Today", D3.formatted_date(today, today_date: today)
    assert_not_equal "Today", D3.formatted_date(today - 1, today_date: today)
    assert_equal "Today", D3.formatted_date(Date.new(2020, 1, 2), today_date: Date.new(2020, 1, 2))
  end

  test "formatted_date returns the formatted date" do
    assert_equal "May  4, 2020", D3.formatted_date(Date.new(2020, 5, 4))
    assert_equal "Dec 13, 2020", D3.formatted_date(Date.new(2020, 12, 13))
  end

  test "formatted_date_with_timezone returns 'Today' when the date is today" do
    travel_to Time.utc(2020, 6, 15, 12, 0, 0) do
      assert_equal "Today", D3.formatted_date_with_timezone(Time.current, "UTC")
      assert_not_equal "Today", D3.formatted_date_with_timezone(Time.current - 1.day, "UTC")
    end
  end

  test "formatted_date_with_timezone formats the date for a given timezone" do
    assert_equal "May  4, 2020", D3.formatted_date_with_timezone(Time.utc(2020, 5, 4), "UTC")
    assert_equal "May  3, 2020", D3.formatted_date_with_timezone(Time.utc(2020, 5, 4), "America/Los_Angeles")
  end

  test "date_domain returns date strings in 'Day, Month Day' format" do
    dates = Date.parse("2013-03-01")..Date.parse("2013-03-02")
    assert_equal ["Friday, March 1st", "Saturday, March 2nd"], D3.date_domain(dates)
  end

  test "date_month_domain returns proper months across year boundaries" do
    dates = Date.parse("2018-12-31")..Date.parse("2019-01-01")
    expected = [
      { date: "Monday, December 31st", month: "December 2018", month_index: 0 },
      { date: "Tuesday, January 1st", month: "January 2019", month_index: 1 }
    ]
    assert_equal expected, D3.date_month_domain(dates)
  end
end
