# frozen_string_literal: true

require "spec_helper"

describe RetryPendingRefundFeeDebitsJob do
  describe "#perform" do
    it "retries refunds marked pending_retry" do
      pending = create(:refund)
      pending.update!(debited_stripe_transfer: Credit::FEE_DEBIT_PENDING_RETRY)
      other = create(:refund)
      other.update!(debited_stripe_transfer: "tr_done")

      expect(Credit).to receive(:create_for_refund_fee_retention!).with(refund: pending)
      expect(Credit).not_to receive(:create_for_refund_fee_retention!).with(refund: other)

      described_class.new.perform
    end

    it "retries refunds with fee retention still pending" do
      pending = create(:refund)
      pending.update!(refund_fee_retention_pending: true)

      expect(Credit).to receive(:create_for_refund_fee_retention!).with(refund: pending)

      described_class.new.perform
    end

    it "continues when one refund raises" do
      first = create(:refund)
      first.update!(debited_stripe_transfer: Credit::FEE_DEBIT_PENDING_RETRY)
      second = create(:refund)
      second.update!(debited_stripe_transfer: Credit::FEE_DEBIT_PENDING_RETRY)
      allow(Credit).to receive(:create_for_refund_fee_retention!).with(refund: first).and_raise(Stripe::StripeError, "boom")
      allow(Credit).to receive(:create_for_refund_fee_retention!).with(refund: second)
      allow(ErrorNotifier).to receive(:notify)

      described_class.new.perform

      expect(Credit).to have_received(:create_for_refund_fee_retention!).with(refund: second)
      expect(ErrorNotifier).to have_received(:notify).with(instance_of(Stripe::StripeError), hash_including(context: hash_including(refund_id: first.id)))
    end
  end
end
