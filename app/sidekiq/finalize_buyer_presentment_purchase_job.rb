# frozen_string_literal: true

# Finalizes a standalone purchase once Stripe exposes settlement data.
class FinalizeBuyerPresentmentPurchaseJob
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :default, lock: :until_executed

  INITIAL_DELAY = 10.seconds
  RETRY_DELAYS = [30.seconds, 1.minute, 5.minutes, 15.minutes, 1.hour, 3.hours].freeze

  def perform(purchase_id, attempt = 0)
    purchase = Purchase.find(purchase_id)
    return unless purchase.pending_buyer_presentment_settlement?
    # Deliberately syncs with mark_as_failed false: this job only runs after a succeeded
    # PaymentIntent, so failing here would turn a transient Stripe lookup error into a false
    # payment failure. SyncStuckPurchasesJob resolves genuinely stuck rows with mark_as_failed true.
    return if Purchase::SyncStatusWithChargeProcessorService.new(purchase).perform

    if (delay = RETRY_DELAYS[attempt])
      self.class.perform_in(delay, purchase_id, attempt + 1)
    else
      ErrorNotifier.notify(
        "Buyer-presentment purchase is still missing Stripe settlement data after retries",
        context: { purchase_id: purchase.id, purchase_external_id: purchase.external_id }
      )
    end
  end
end
