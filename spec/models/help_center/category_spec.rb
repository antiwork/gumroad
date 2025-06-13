# frozen_string_literal: true

require "spec_helper"

describe HelpCenter::Category do
  describe "#categories_for_same_audience" do
    it "returns the categories with the same audience" do
      expect(HelpCenter::Category::ACCESSING_YOUR_PURCHASE.categories_for_same_audience).to contain_exactly(
        HelpCenter::Category::ACCESSING_YOUR_PURCHASE,
        HelpCenter::Category::BEFORE_YOU_BUY,
        HelpCenter::Category::RECEIPTS_AND_REFUNDS,
        HelpCenter::Category::ISSUES_WITH_YOUR_PURCHASE
      )
    end
  end
end
