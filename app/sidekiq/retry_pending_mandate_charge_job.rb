# frozen_string_literal: true

# Charges the seller groups of an India multi-seller cart that Order::ConfirmService held back
# because the buyer's e-mandate was still `pending`, and fails them once the wait runs out.
class RetryPendingMandateChargeJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default, lock: :until_executing

  MAX_WAIT = 30.minutes
  RETRY_INTERVAL = 1.minute
  PENDING_MESSAGE = "Your bank is still confirming your card for recurring payments. Please try again in a few minutes, or buy from one creator at a time."

  def perform(order_id, buyer_currency_quote = nil)
    order = Order.find_by(id: order_id)
    return if order.blank?

    params = { buyer_currency_quote: }
    service = Order::ConfirmService.new(order:, params:)
    service.charge_pending_setup_groups!

    # Groups the charge declined or could not create carry errors but are still in progress.
    order.purchases.select { |purchase| purchase.in_progress? && purchase.errors.any? }.each do |purchase|
      Purchase::ConfirmService.new(purchase:, params:).perform
    end

    held = service.mandate_pending_purchases.select(&:in_progress?)
    return if held.none?

    if held.map(&:created_at).min + MAX_WAIT > Time.current
      self.class.perform_in(RETRY_INTERVAL, order_id, buyer_currency_quote)
    else
      held.each { |purchase| fail_unpaid!(purchase) }
    end
  end

  private
    # A buyer retry can charge the group between the read above and this lock, so recheck first.
    def fail_unpaid!(purchase)
      purchase.with_lock do
        next unless purchase.in_progress?
        next if purchase.processor_payment_intent.present? || purchase.stripe_transaction_id.present?
        next if purchase.charge&.client_confirmed?

        purchase.error_code = PurchaseErrorCode::INDIA_CARD_MANDATE_PENDING
        purchase.errors.add(:base, PENDING_MESSAGE)
        Purchase::MarkFailedService.new(purchase).perform
      end
    end
end
