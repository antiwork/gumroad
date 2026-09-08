# frozen_string_literal: true

# Safety net for outstanding fee retention / pending_retry markers when the per-refund
# enqueue was lost. Dispatches RetryRefundFeeRetentionJob. Bounded to recently updated
# refunds so MySQL is not forced to examine the entire refunds history every run.
class RetryPendingRefundFeeDebitsJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default, lock: :until_executed

  include RecurringLockTtl
  recurring_lock_ttl max_attempt: 5.minutes

  LOOKBACK = 30.days

  def perform
    Refund.pending_fee_debit_retry
          .where("refunds.updated_at > ?", LOOKBACK.ago)
          .find_each do |refund|
      next if refund.balance_reversed_on_failure

      RetryRefundFeeRetentionJob.perform_async(refund.id)
    end
  end
end
