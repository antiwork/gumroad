# frozen_string_literal: true

require "spec_helper"

describe RetryStripePayoutForSettlingTransferJob do
  describe "#perform" do
    it "re-attempts the bank payout for a processing payment with no payout yet" do
      payment = create(:payment, processor: PayoutProcessorType::STRIPE, state: "processing")

      expect(StripePayoutProcessor).to receive(:perform_payment) do |arg|
        expect(arg.id).to eq(payment.id)
      end

      described_class.new.perform(payment.id)
    end

    it "does nothing when the payment is no longer processing" do
      payment = create(:payment, processor: PayoutProcessorType::STRIPE, state: "cancelled")

      expect(StripePayoutProcessor).not_to receive(:perform_payment)

      described_class.new.perform(payment.id)
    end

    it "does nothing when a bank payout already exists" do
      payment = create(:payment, processor: PayoutProcessorType::STRIPE, state: "processing", stripe_transfer_id: "po_existing")

      expect(StripePayoutProcessor).not_to receive(:perform_payment)

      described_class.new.perform(payment.id)
    end
  end
end
