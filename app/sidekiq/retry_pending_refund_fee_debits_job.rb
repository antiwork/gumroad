# frozen_string_literal: true

# Safety net for outstanding fee retention / pending_retry / holding-reconcile work when
# the per-refund enqueue was lost. Dispatches RetryRefundFeeRetentionJob via the indexed
# fee_retention_retry_at queue (no JSON history scan).
class RetryPendingRefundFeeDebitsJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default, lock: :until_executed

  include RecurringLockTtl
  recurring_lock_ttl max_attempt: 5.minutes

  def perform
    Refund.pending_fee_debit_retry
          .where("refunds.fee_retention_retry_at <= ?", Time.current)
          .find_each do |refund|
      next if refund.balance_reversed_on_failure

      RetryRefundFeeRetentionJob.perform_async(refund.id)
    end
  end
end
