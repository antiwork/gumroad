# frozen_string_literal: true

# Safety net for refund fee debits left pending when the per-refund enqueue was lost.
# Only considers refunds still inside the Stripe idempotency window and dispatches the
# per-refund job rather than doing Stripe work inline.
class RetryPendingRefundFeeDebitsJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default, lock: :until_executed

  include RecurringLockTtl
  recurring_lock_ttl max_attempt: 5.minutes

  def perform
    Refund.pending_fee_debit_retry
          .where("refunds.created_at > ?", Credit::FEE_DEBIT_IDEMPOTENCY_WINDOW.ago)
          .find_each do |refund|
      next if refund.balance_reversed_on_failure

      RetryRefundFeeRetentionJob.perform_async(refund.id)
    end
  end
end
