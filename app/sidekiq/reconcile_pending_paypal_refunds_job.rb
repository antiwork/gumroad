# frozen_string_literal: true

# PayPal does not send a webhook when an accepted refund later fails, so reconcile
# pending refunds to ensure failures reach the existing exception queue.
class ReconcilePendingPaypalRefundsJob
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :low, lock: :until_executed

  # Hourly cron: keep max_attempt under the interval minus
  # RecurringLockTtl::SAFETY_MARGIN so a stranded lock digest cannot mute the next fire.
  include RecurringLockTtl
  recurring_lock_ttl max_attempt: 45.minutes

  # PayPal's statuses, with the lowercase values Refund::TERMINAL_FAILURE_STATUSES uses.
  # Both cases are accepted in both directions: a row we failed to recognise would be
  # the silent PENDING this job exists to end.
  PAYPAL_PENDING_STATUSES = %w(PENDING pending).freeze
  PAYPAL_COMPLETED_STATUS = "COMPLETED"
  PAYPAL_TERMINAL_FAILURE_STATUSES = { "FAILED" => "failed", "CANCELLED" => "canceled" }.freeze

  # Only refunds past this age are worth a round-trip; a younger one can still settle. No
  # upper bound, because the scope is `status = "PENDING"` alone and every read either
  # resolves the row or proves it is stuck.
  MINIMUM_AGE = 3.days

  def perform
    refunds_to_reconcile.find_each do |refund|
      reconcile(refund)
    rescue StandardError => e
      Rails.logger.error("Reconciling pending PayPal refund #{refund.id} failed: #{e.class}: #{e.message}")
      ErrorNotifier.notify(e, context: { refund_id: refund.id, purchase_id: refund.purchase_id })
    end
  end

  private
    def refunds_to_reconcile
      Refund.joins(:purchase)
            .where(status: PAYPAL_PENDING_STATUSES)
            .where.not(processor_refund_id: [nil, ""])
            .where(purchases: { charge_processor_id: PaypalChargeProcessor.charge_processor_id })
            .where(created_at: ...MINIMUM_AGE.ago)
    end

    def reconcile(refund)
      purchase = refund.purchase
      processor_status = PaypalChargeProcessor.fetch_refund_status(
        processor_refund_id: refund.processor_refund_id,
        merchant_account: purchase.merchant_account ||
          purchase.seller.merchant_account(PaypalChargeProcessor.charge_processor_id)
      ).to_s.upcase

      case processor_status
      when PAYPAL_COMPLETED_STATUS
        refund.update!(status: PAYPAL_COMPLETED_STATUS)
      when *PAYPAL_TERMINAL_FAILURE_STATUSES.keys
        Purchase::HandleFailedRefundService.new(
          refund:,
          failure_status: PAYPAL_TERMINAL_FAILURE_STATUSES.fetch(processor_status)
        ).perform
      end
    end
end
