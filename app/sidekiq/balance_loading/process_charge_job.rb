# frozen_string_literal: true

module BalanceLoading
  class ProcessChargeJob
    include Sidekiq::Job

    sidekiq_options queue: :default, retry: 3

    def perform(balance_load_id)
      balance_load = BalanceLoad.find(balance_load_id)
      return unless balance_load.pending?

      # Retrieve latest PaymentIntent status from Stripe
      payment_intent = Stripe::PaymentIntent.retrieve(balance_load.stripe_payment_intent_id)

      case payment_intent.status
      when "succeeded"
        handle_success(balance_load, payment_intent)
      when "requires_action", "processing"
        # Still pending, retry in 5 seconds
        Rails.logger.info("BalanceLoad #{balance_load_id} still requires action, will retry in 5 seconds")
        self.class.perform_in(5.seconds, balance_load_id)
      else
        # Failed
        handle_failure(balance_load, "Payment failed with status: #{payment_intent.status}")
      end
    rescue Stripe::StripeError => e
      handle_failure(balance_load, e.message)
      raise # Let Sidekiq handle retry
    rescue ActiveRecord::RecordNotFound => e
      Rails.logger.error("BalanceLoad #{balance_load_id} not found")
      # Don't retry if record doesn't exist
    end

    private

    def handle_success(balance_load, payment_intent)
      charge = payment_intent.charges.data.first
      balance_load.update!(
        stripe_charge_id: charge.id,
        processor_fee_cents: charge.application_fee_amount || 0,
        metadata: { charge_id: charge.id, balance_transaction: charge.balance_transaction }.to_json
      )
      balance_load.mark_successful!
      Rails.logger.info("BalanceLoad #{balance_load.id} succeeded after 3DS")
    end

    def handle_failure(balance_load, error_message)
      return unless balance_load

      balance_load.update!(error_message:)
      balance_load.mark_failed!
      Rails.logger.error("BalanceLoad #{balance_load.id} failed: #{error_message}")
    end
  end
end
