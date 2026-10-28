# frozen_string_literal: true

# Charges the seller groups of an India multi-seller cart that Order::ConfirmService held back
# because the buyer's e-mandate was still `pending`, and fails them once the wait runs out.
class RetryPendingMandateChargeJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default, lock: :until_executing

  MAX_WAIT = 30.minutes
  RETRY_INTERVAL = 1.minute
  PENDING_MESSAGE = "Your bank is still confirming your card for recurring payments. Please try again in a few minutes, or buy from one creator at a time."

  # Order::ConfirmService marks a held purchase with a `processing` stripe_status (so payment_settling
  # blocks a repeat buy) before anything is submitted to Stripe.
  def self.held?(purchase)
    purchase.in_progress? &&
      purchase.stripe_status == StripeIntentStatus::PROCESSING &&
      purchase.processor_setup_intent_id.present? &&
      purchase.processor_payment_intent.blank? &&
      purchase.stripe_transaction_id.blank? &&
      !purchase.charge&.client_confirmed?
  end

  def self.wait_over?(purchases)
    purchases.map(&:created_at).min + MAX_WAIT <= Time.current
  end

  # A buyer retry can charge the group between the caller's read and this lock, so recheck first.
  def self.fail_unpaid!(purchase)
    purchase.with_lock do
      next unless purchase.in_progress?
      next if purchase.processor_payment_intent.present? || purchase.stripe_transaction_id.present?
      next if purchase.charge&.client_confirmed?

      purchase.stripe_status = nil
      purchase.error_code = PurchaseErrorCode::INDIA_CARD_MANDATE_PENDING
      purchase.errors.add(:base, PENDING_MESSAGE)
      Purchase::MarkFailedService.new(purchase).perform
    end
  end

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
    # OrdersController#confirm sends these after its charge pass; a group charged here needs the same.
    order.send_charge_receipts

    held = service.mandate_pending_purchases.select(&:in_progress?)
    return if held.none?

    if self.class.wait_over?(held)
      held.each { |purchase| self.class.fail_unpaid!(purchase) }
    else
      self.class.perform_in(RETRY_INTERVAL, order_id, buyer_currency_quote)
    end
  end
end
