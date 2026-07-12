# frozen_string_literal: true

class RefundPurchaseWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  # reason is either Refund::FRAUD (which routes to the dedicated fraud path) or a
  # free-text explanation. The explanation is stored on the refund and emailed to the
  # creator; the refund model requires it for team-member refunds that aren't for fraud.
  def perform(purchase_id, admin_user_id, reason = nil)
    purchase = Purchase.find(purchase_id)

    if reason == Refund::FRAUD
      purchase.refund_for_fraud_and_block_buyer!(admin_user_id)
    else
      purchase.refund_and_save!(admin_user_id, reason:)
    end
  end
end
