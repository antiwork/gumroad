# frozen_string_literal: true

require "spec_helper"

describe RetryRefundFeeRetentionJob do
  describe "#perform" do
    it "re-runs fee retention for the refund" do
      refund = create(:refund)
      expect(Credit).to receive(:create_for_refund_fee_retention!).with(refund:)

      described_class.new.perform(refund.id)
    end

    it "no-ops when the refund is missing" do
      expect(Credit).not_to receive(:create_for_refund_fee_retention!)

      described_class.new.perform(-1)
    end

    it "skips refunds whose balance was reversed on failure" do
      refund = create(:refund)
      refund.update!(balance_reversed_on_failure: true)
      expect(Credit).not_to receive(:create_for_refund_fee_retention!)

      described_class.new.perform(refund.id)
    end
  end
end
