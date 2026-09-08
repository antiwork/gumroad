# frozen_string_literal: true

# Safety net for refund fee debits left in pending_retry when the per-refund enqueue was
# lost. Runs inside the Stripe idempotency window so create_for_refund_fee_retention!
# can still finish the debit.
class RetryPendingRefundFeeDebitsJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default, lock: :until_executed

  include RecurringLockTtl
  recurring_lock_ttl max_attempt: 5.minutes

  def perform
    Refund.pending_fee_debit_retry.find_each do |refund|
      next if refund.balance_reversed_on_failure

      Credit.create_for_refund_fee_retention!(refund:)
    rescue StandardError => e
      Rails.logger.error("Failed pending refund fee debit retry for refund #{refund.id}: #{e.class}: #{e.message}")
      ErrorNotifier.notify(e, context: { refund_id: refund.id, purchase_id: refund.purchase_id })
    end
  end
end
