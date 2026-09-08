# frozen_string_literal: true

# Recovers SetupIntent-confirmed India charges whose create response was lost
# (client_confirmed without a stored PaymentIntent). Searches Stripe Charges and
# PaymentIntents by transfer_group, then syncs — does not create a new PaymentIntent.
class ReconcileClientConfirmedChargeJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default, lock: :until_executed

  # India processing debits can take up to ~26h before a Charge object exists.
  RETRY_DELAYS = [
    30.seconds, 1.minute, 5.minutes, 15.minutes, 1.hour,
    3.hours, 6.hours, 12.hours, 24.hours
  ].freeze

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
    if delay
      self.class.perform_in(delay, charge_id, attempt + 1)
      return
    end

    # Exhausted the India processing window with no recoverable PaymentIntent: clear settling
    # markers so payment_settling does not block the buyer forever, and fail uncharged rows.
    return if charge.stripe_payment_intent_id.present?

    ErrorNotifier.notify(
      "ReconcileClientConfirmedChargeJob exhausted without finding a PaymentIntent",
      charge_id: charge.id
    )
    charge.update!(client_confirmed: false)
    charge.purchases.select(&:in_progress?).each do |purchase|
      next if purchase.processor_payment_intent.present?

      purchase.update!(stripe_status: nil) if purchase.stripe_status.present?
      purchase.errors.add(:base, "There is a temporary problem, please try again (your card was not charged).") if purchase.errors.empty?
      Purchase::MarkFailedService.new(purchase).perform
    end
  end

  private
    def recover_missing_payment_intent!(charge)
      return if charge.stripe_payment_intent_id.present?

      purchase = charge.purchases.find(&:in_progress?) || charge.purchases.first
      return if purchase.blank? || purchase.charge_processor_id.blank?

      payment_intent_id = payment_intent_id_from_stripe_charge(
        ChargeProcessor.search_charge(charge_processor_id: purchase.charge_processor_id, purchase:)
      )
      payment_intent_id ||= search_payment_intent_id_by_transfer_group(charge, purchase)
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

    def search_payment_intent_id_by_transfer_group(charge, purchase)
      transfer_group = charge.id_with_prefix
      stripe_opts = if purchase.charged_using_stripe_connect_account?
        { stripe_account: purchase.merchant_account.charge_processor_merchant_id }
      else
        {}
      end
      created_gte = [charge.created_at.to_i - 120, 0].max
      list_params = { created: { gte: created_gte }, limit: 100 }
      intents = Stripe::PaymentIntent.list(list_params, stripe_opts)
      loop do
        match = intents.data.find { |intent| intent.transfer_group.to_s == transfer_group.to_s }
        return match.id if match.present?
        break unless intents.respond_to?(:has_more) && intents.has_more && intents.data.present?

        intents = Stripe::PaymentIntent.list(
          list_params.merge(starting_after: intents.data.last.id),
          stripe_opts
        )
      end
      nil
    end
end
