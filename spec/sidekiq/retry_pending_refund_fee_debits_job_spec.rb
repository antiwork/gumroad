# frozen_string_literal: true

require "spec_helper"

describe RetryPendingRefundFeeDebitsJob do
  describe "#perform" do
    it "enqueues per-refund retries for pending_retry refunds" do
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
  end
end
