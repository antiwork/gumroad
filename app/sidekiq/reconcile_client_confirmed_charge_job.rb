# frozen_string_literal: true

# Recovers SetupIntent-confirmed India charges whose create response was lost
# (client_confirmed without a stored PaymentIntent). Syncs each in-progress purchase so
# ChargeProcessor can search Stripe by transfer_group and finalize — does not create a new
# PaymentIntent with different presentment params.
class ReconcileClientConfirmedChargeJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default, lock: :until_executed

  RETRY_DELAYS = [30.seconds, 1.minute, 5.minutes, 15.minutes, 1.hour].freeze

  def perform(charge_id, attempt = 0)
    charge = Charge.find_by(id: charge_id)
    return if charge.blank?
    return unless charge.client_confirmed?
    return if charge.purchases.none?(&:in_progress?)

    charge.purchases.select(&:in_progress?).each do |purchase|
      Purchase::SyncStatusWithChargeProcessorService.new(purchase).perform
    end

    charge.reload
    return if charge.purchases.none?(&:in_progress?)

    delay = RETRY_DELAYS[attempt]
    self.class.perform_in(delay, charge_id, attempt + 1) if delay
  end
end
