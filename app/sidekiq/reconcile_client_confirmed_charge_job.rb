# frozen_string_literal: true

# Recovers SetupIntent-confirmed India charges whose create response was lost
# (client_confirmed without a stored PaymentIntent). Searches Stripe by transfer_group to
# persist the PaymentIntent id, then syncs — does not create a new PaymentIntent with
# different presentment params.
class ReconcileClientConfirmedChargeJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default, lock: :until_executed

  RETRY_DELAYS = [30.seconds, 1.minute, 5.minutes, 15.minutes, 1.hour].freeze

  def perform(charge_id, attempt = 0)
    charge = Charge.find_by(id: charge_id)
    return if charge.blank?
    return unless charge.client_confirmed?
    return if charge.purchases.none?(&:in_progress?)

    recover_missing_payment_intent!(charge)

    charge.purchases.select(&:in_progress?).each do |purchase|
      Purchase::SyncStatusWithChargeProcessorService.new(purchase).perform
    end

    charge.reload
    return if charge.purchases.none?(&:in_progress?)

    delay = RETRY_DELAYS[attempt]
    self.class.perform_in(delay, charge_id, attempt + 1) if delay
  end

  private
    # Order::FinalizeConfirmedChargeService returns processing when stripe_payment_intent_id is
    # blank and never searches Stripe. Recover the intent from the charge's transfer_group first.
    def recover_missing_payment_intent!(charge)
      return if charge.stripe_payment_intent_id.present?

      purchase = charge.purchases.find(&:in_progress?) || charge.purchases.first
      return if purchase.blank? || purchase.charge_processor_id.blank?

      stripe_charge = ChargeProcessor.search_charge(
        charge_processor_id: purchase.charge_processor_id,
        purchase:
      )
      payment_intent_id = payment_intent_id_from_stripe_charge(stripe_charge)
      return if payment_intent_id.blank?

      charge.update!(stripe_payment_intent_id: payment_intent_id)
      charge.purchases.select(&:in_progress?).each do |in_progress_purchase|
        next if in_progress_purchase.processor_payment_intent.present?

        in_progress_purchase.create_processor_payment_intent!(intent_id: payment_intent_id)
      end
    rescue StandardError => e
      ErrorNotifier.notify(e, charge_id: charge.id)
    end

    def payment_intent_id_from_stripe_charge(stripe_charge)
      return if stripe_charge.blank?

      payment_intent = if stripe_charge.respond_to?(:[])
        stripe_charge[:payment_intent] || stripe_charge["payment_intent"]
      else
        stripe_charge.try(:payment_intent)
      end
      payment_intent = payment_intent.id if payment_intent.respond_to?(:id)
      payment_intent.presence
    end
end
