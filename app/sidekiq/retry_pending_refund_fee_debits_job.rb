# frozen_string_literal: true

# Safety net for outstanding fee retention / pending_retry markers when the per-refund
# enqueue was lost. Dispatches RetryRefundFeeRetentionJob; create_for_refund_fee_retention!
# refuses expired Stripe resubmits but still finishes holding lookups for confirmed debits.
class RetryPendingRefundFeeDebitsJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default, lock: :until_executed

  include RecurringLockTtl
  recurring_lock_ttl max_attempt: 5.minutes

  def perform
    Refund.pending_fee_debit_retry.find_each do |refund|
      next if refund.balance_reversed_on_failure

      RetryRefundFeeRetentionJob.perform_async(refund.id)
    end
  end
end
