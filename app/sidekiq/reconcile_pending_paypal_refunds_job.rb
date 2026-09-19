# frozen_string_literal: true

# PayPal sends no refund-failed webhook — PAYMENT.CAPTURE.REFUNDED fires only when a
# refund completes — so a refund PayPal accepted as PENDING and later failed keeps that
# status on our row forever: it stays inside Refund.effective as money that moved, and
# never reaches the FailedRefundException queue that exists to resolve it. This job is
# the missing trigger, reusing the same service the Stripe lane already calls.
class ReconcilePendingPaypalRefundsJob
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :low, lock: :until_executed

  # Hourly cron: keep max_attempt under the interval minus
  # RecurringLockTtl::SAFETY_MARGIN so a stranded lock digest cannot mute the next fire.
  include RecurringLockTtl
  recurring_lock_ttl max_attempt: 45.minutes

  # PayPal's refund statuses. The lowercase values on the right are what
  # Refund::TERMINAL_FAILURE_STATUSES understands, so a refund failed on PayPal is
  # indistinguishable downstream from one failed on Stripe.
  PAYPAL_PENDING_STATUS = "PENDING"
  PAYPAL_COMPLETED_STATUS = "COMPLETED"
  PAYPAL_TERMINAL_FAILURE_STATUSES = { "FAILED" => "failed", "CANCELLED" => "canceled" }.freeze

  # A refund PayPal is still holding as PENDING can settle later, so only rows past this
  # age are worth a round-trip. There is no upper bound: the candidate scope is
  # `status = "PENDING"` alone, and every read either resolves the row or proves it is
  # still stuck, so a refund that never settles keeps being checked rather than being
  # dropped after an arbitrary window.
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
            .where(status: PAYPAL_PENDING_STATUS)
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
      )

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