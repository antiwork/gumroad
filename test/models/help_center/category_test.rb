# frozen_string_literal: true

require "test_helper"

class HelpCenter::CategoryTest < ActiveSupport::TestCase
  test "#categories_for_same_audience returns categories sharing the same audience" do
    expected = [
      HelpCenter::Category::ACCESSING_YOUR_PURCHASE,
      HelpCenter::Category::BEFORE_YOU_BUY,
      HelpCenter::Category::RECEIPTS_AND_REFUNDS,
      HelpCenter::Category::ISSUES_WITH_YOUR_PURCHASE,
    ]
    assert_equal expected.sort_by(&:id),
                 HelpCenter::Category::ACCESSING_YOUR_PURCHASE.categories_for_same_audience.sort_by(&:id)
  end
end
