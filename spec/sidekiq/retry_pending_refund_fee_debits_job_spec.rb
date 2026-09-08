# frozen_string_literal: true

require "spec_helper"

describe RetryPendingRefundFeeDebitsJob do
  describe "#perform" do
    it "enqueues per-refund retries for indexed pending work" do
      pending = create(:refund)
      pending.update!(
        debited_stripe_transfer: Credit::FEE_DEBIT_PENDING_RETRY,
        fee_retention_retry_at: 1.minute.ago
      )
      other = create(:refund)
      other.update!(debited_stripe_transfer: "tr_done", fee_retention_retry_at: nil)

      described_class.new.perform

      expect(RetryRefundFeeRetentionJob).to have_enqueued_sidekiq_job(pending.id)
      expect(RetryRefundFeeRetentionJob).not_to have_enqueued_sidekiq_job(other.id)
    end

    it "enqueues refunds with fee retention still pending" do
      pending = create(:refund)
      pending.update!(refund_fee_retention_pending: true, fee_retention_retry_at: Time.current)

      described_class.new.perform

      expect(RetryRefundFeeRetentionJob).to have_enqueued_sidekiq_job(pending.id)
    end

    it "skips work scheduled in the future" do
      pending = create(:refund)
      pending.update!(fee_retention_retry_at: 1.hour.from_now)

      described_class.new.perform

      expect(RetryRefundFeeRetentionJob).not_to have_enqueued_sidekiq_job(pending.id)
    end
  end
end
