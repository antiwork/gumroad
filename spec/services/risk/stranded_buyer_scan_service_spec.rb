# frozen_string_literal: true

require "spec_helper"

describe Risk::StrandedBuyerScanService do
  describe "#reject_disputed" do
    it "does not drop a buyer whose only chargeback is PayPal-processor" do
      email = "paypal-buyer@example.com"
      paypal = create(:purchase, email:, chargeback_date: Time.current)
      paypal.update_column(:charge_processor_id, PaypalChargeProcessor.charge_processor_id)

      settled = { email => 3 }
      expect(described_class.new.send(:reject_disputed, settled)).to eq(settled)
    end

    it "still drops a buyer with a Stripe chargeback" do
      email = "stripe-buyer@example.com"
      create(:purchase, email:, chargeback_date: Time.current)

      expect(described_class.new.send(:reject_disputed, { email => 3 })).to eq({})
    end
  end
end
