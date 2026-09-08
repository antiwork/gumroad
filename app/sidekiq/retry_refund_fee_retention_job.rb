# frozen_string_literal: true

# Retries Credit.create_for_refund_fee_retention! for one refund after a transient Stripe
# fee-debit failure (pending_retry). Idempotent; refuses automatic resubmit after the
# Stripe idempotency window.
class RetryRefundFeeRetentionJob
  include Sidekiq::Job
  sidekiq_options retry: 10, queue: :default, lock: :until_executed

  def perform(refund_id)
    refund = Refund.find_by(id: refund_id)
    return if refund.blank?
    return if refund.balance_reversed_on_failure

    Credit.create_for_refund_fee_retention!(refund:)
  end
end
