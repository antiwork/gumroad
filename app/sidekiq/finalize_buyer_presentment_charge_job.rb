# frozen_string_literal: true

# Buyer-presentment charges defer purchase finalization until Stripe produces the charge's
# balance transaction (flow of funds), because seller/affiliate balances must be booked from
# real settlement data. This job polls the processor charge and finalizes the purchases once
# settlement data exists, then sends the receipt the checkout response withheld.
#
# PR-1 eligibility guarantees a presentment charge contains exactly one purchase, so the
# receipt for the charge cannot have been sent before that purchase became successful.
class FinalizeBuyerPresentmentChargeJob
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :default, lock: :until_executed

  INITIAL_DELAY = 10.seconds
  RETRY_DELAYS = [30.seconds, 1.minute, 5.minutes, 15.minutes, 1.hour, 3.hours].freeze

  def perform(charge_id, attempt = 0)
    charge = Charge.find(charge_id)
    return if charge.charge_presentment.blank?

    pending_purchases = charge.purchases.select { _1.in_progress? && _1.stripe_transaction_id.present? }
    if pending_purchases.none?
      # No purchase is awaiting settlement. If the purchases already finalized but the
      # post-finalization SendChargeReceiptJob enqueue failed (e.g. a transient Redis error),
      # the receipt would be orphaned: a Sidekiq retry of this job finds pending_purchases empty
      # and SyncStuckPurchasesJob only recovers in_progress purchases. Re-enqueue the receipt so a
      # retry closes the gap. SendChargeReceiptJob no-ops when charge.receipt_sent?.
      enqueue_receipt(charge) if charge.purchases.any?(&:successful?) && !charge.receipt_sent?
      return
    end

    finalized = pending_purchases.all? { Purchase::SyncStatusWithChargeProcessorService.new(_1).perform }

    if finalized
      enqueue_receipt(charge)
    elsif (delay = RETRY_DELAYS[attempt])
      self.class.perform_in(delay, charge_id, attempt + 1)
    else
      # SyncStuckPurchasesJob remains the long-tail backstop; alert so a human can look at
      # why Stripe settlement data still has not arrived.
      ErrorNotifier.notify(
        "Buyer-presentment charge is still missing Stripe settlement data after retries",
        context: { charge_id: charge.id, charge_external_id: charge.external_id }
      )
    end
  end

  private
    def enqueue_receipt(charge)
      SendChargeReceiptJob.set(queue: charge.purchases_requiring_stamping.any? ? "default" : "critical").perform_async(charge.id)
    end
end
