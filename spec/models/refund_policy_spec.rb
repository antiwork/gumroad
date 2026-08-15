# frozen_string_literal: true

require "spec_helper"

describe RefundPolicy do
  describe ".periods_in_days" do
    it "excludes no-refunds by default" do
      expect(described_class.periods_in_days).to eq([7, 14, 30, 183])
    end

    it "includes no-refunds when allowed" do
      expect(described_class.periods_in_days(allow_no_refunds: true)).to eq([0, 7, 14, 30, 183])
    end
  end

  describe "#effective_max_refund_period_in_days" do
    let(:policy) { SellerRefundPolicy.new(max_refund_period_in_days: 0) }

    it "floors a 0-day account policy to 7 days" do
      expect(policy.effective_max_refund_period_in_days).to eq(7)
      expect(policy.title).to eq("7-day money back guarantee")
    end
  end
end
