# frozen_string_literal: true

# Refunds a single purchase for fraud as part of a bulk RefundAllForFraudWorker run.
#
# block_buyers: false (seller-fraud case) refunds without touching the buyer;
# true (buyer-fraud case) also blocks the buyer platform-wide. Already-refunded
# purchases (a race with a concurrent refund) return nil from the refund primitives
# and are treated as a clean skip — no blocking, no subscription side effects.
# Failures are reported to ErrorNotifier and re-raised so Sidekiq retries them.
class RefundPurchaseForFraudWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  def perform(purchase_id, admin_user_id, block_buyers = false)
    purchase = Purchase.find(purchase_id)

    result =
      if block_buyers
        purchase.refund_for_fraud_and_block_buyer!(admin_user_id, skip_already_refunded: true)
      else
        purchase.refund_for_fraud!(admin_user_id, skip_already_refunded: true)
      end

    # nil means there was nothing left to refund (already refunded elsewhere) — a
    # clean skip. false means the refund failed with a purchase error; raise so the
    # failure is visible in Sentry and Sidekiq retries it.
    if result == false
      raise "Bulk fraud refund failed for purchase #{purchase.external_id_numeric}: " \
            "#{purchase.errors.full_messages.presence&.to_sentence || "refund was not processed"}"
    end
  rescue StandardError => e
    ErrorNotifier.notify(e) do |event|
      event.add_metadata(:refund_all_for_fraud, {
                           purchase_id:,
                           admin_user_id:,
                           block_buyers:,
                         })
    end
    raise
  end
end
