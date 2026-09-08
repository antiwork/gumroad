# frozen_string_literal: true

require "spec_helper"

describe RetryPendingRefundFeeDebitsJob do
  describe "#perform" do
    it "enqueues per-refund retries for pending_retry refunds inside the window" do
      pending = create(:refund)
      pending.update!(debited_stripe_transfer: Credit::FEE_DEBIT_PENDING_RETRY)
      other = create(:refund)
      other.update!(debited_stripe_transfer: "tr_done")

      described_class.new.perform

      expect(RetryRefundFeeRetentionJob).to have_enqueued_sidekiq_job(pending.id)
      expect(RetryRefundFeeRetentionJob).not_to have_enqueued_sidekiq_job(other.id)
    end

    it "enqueues refunds with fee retention still pending" do
      pending = create(:refund)
      pending.update!(refund_fee_retention_pending: true)

      described_class.new.perform

      expect(RetryRefundFeeRetentionJob).to have_enqueued_sidekiq_job(pending.id)
    end

    it "skips refunds older than the idempotency window" do
      stale = create(:refund, created_at: (Credit::FEE_DEBIT_IDEMPOTENCY_WINDOW + 1.hour).ago)
      stale.update!(debited_stripe_transfer: Credit::FEE_DEBIT_PENDING_RETRY)

      described_class.new.perform

      expect(RetryRefundFeeRetentionJob).not_to have_enqueued_sidekiq_job(stale.id)
    end
  end
end
