# frozen_string_literal: true

require "test_helper"

class CreditCardUtilityTest < ActiveSupport::TestCase
  test "extract_month_and_year extracts the month and year from a date" do
    expiry_month, expiry_year = CreditCardUtility.extract_month_and_year("05 / 15")
    assert_equal "05", expiry_month
    assert_equal "15", expiry_year
  end

  test "extract_month_and_year returns nil for an invalid expiry date" do
    assert_equal [nil, nil], CreditCardUtility.extract_month_and_year("05 /")
  end
end
