# frozen_string_literal: true

# Retries SetupIntent-confirmed India charges whose create response was lost (client_confirmed
# without a stored PaymentIntent). Uses Charge::CreateService's setup_confirmed_resume
# idempotency key so Stripe returns the original PaymentIntent when it already exists.
class ReconcileClientConfirmedChargeJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default, lock: :until_executed

  RETRY_DELAYS = [30.seconds, 1.minute, 5.minutes, 15.minutes, 1.hour].freeze

  def perform(charge_id, attempt = 0)
    charge = Charge.find_by(id: charge_id)
    return if charge.blank?
    return unless charge.client_confirmed?
    return if charge.stripe_payment_intent_id.present?
    return if charge.purchases.none?(&:in_progress?)

    order = charge.order
    Order::ConfirmService.new(order:, params: {}).perform

    charge.reload
    return if charge.stripe_payment_intent_id.present? || charge.purchases.none?(&:in_progress?)

    delay = RETRY_DELAYS[attempt]
    self.class.perform_in(delay, charge_id, attempt + 1) if delay
  end
end
