# frozen_string_literal: true

# Finalizes a standalone buyer-presentment purchase once Stripe exposes settlement data.
class FinalizeBuyerPresentmentPurchaseJob
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :default, lock: :until_executed

  INITIAL_DELAY = 10.seconds
  RETRY_DELAYS = [30.seconds, 1.minute, 5.minutes, 15.minutes, 1.hour, 3.hours].freeze

  def perform(purchase_id, attempt = 0)
    purchase = Purchase.find(purchase_id)
    return unless purchase.pending_buyer_presentment_settlement?

    delay = RETRY_DELAYS[attempt]
    # Only the last attempt may fail the purchase: a charge still not succeeding after the full
    # retry window is terminal, and leaving it `in_progress` strands it until the 6-hourly
    # SyncStuckPurchasesJob sweep. Earlier on, a decline is indistinguishable from a processor blip.
    return if Purchase::SyncStatusWithChargeProcessorService.new(purchase, mark_as_failed: delay.nil?).perform

    if delay
      self.class.perform_in(delay, purchase_id, attempt + 1)
    elsif purchase.reload.in_progress?
      ErrorNotifier.notify(
        "Buyer-presentment purchase is still missing Stripe settlement data after retries",
        context: { purchase_id: purchase.id, purchase_external_id: purchase.external_id }
      )
    end
  end
end
