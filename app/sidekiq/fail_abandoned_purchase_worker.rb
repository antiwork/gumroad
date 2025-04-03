# frozen_string_literal: true

class FailAbandonedPurchaseWorker
  include Sidekiq::Job, StripeErrorHandler
  sidekiq_options retry: 5, queue: :default

  attr_reader :purchase

  def perform(purchase_id)
    @purchase = Purchase.find(purchase_id)

    return unless purchase.in_progress?

    # Guard against the job executing too early
    if purchase.created_at + ChargeProcessor::TIME_TO_COMPLETE_SCA > Time.current
      FailAbandonedPurchaseWorker.perform_at(purchase.created_at + ChargeProcessor::TIME_TO_COMPLETE_SCA, purchase_id)
      return
    end

    with_stripe_error_handler do
      merchant_account = purchase.merchant_account
      return if merchant_account&.is_a_stripe_connect_account? && merchant_account.charge_processor_merchant_id.blank?

      if purchase.processor_payment_intent_id.present?
        payment_intent = if merchant_account&.is_a_stripe_connect_account?
          Stripe::PaymentIntent.retrieve(purchase.processor_payment_intent_id, { stripe_account: merchant_account.charge_processor_merchant_id })
        else
          Stripe::PaymentIntent.retrieve(purchase.processor_payment_intent_id)
        end
        cancel_charge_intent unless payment_intent.status == StripeIntentStatus::PROCESSING
      elsif purchase.processor_setup_intent_id.present?
        setup_intent = if merchant_account&.is_a_stripe_connect_account?
          Stripe::SetupIntent.retrieve(purchase.processor_setup_intent_id, { stripe_account: merchant_account.charge_processor_merchant_id })
        else
          Stripe::SetupIntent.retrieve(purchase.processor_setup_intent_id)
        end
        cancel_setup_intent unless setup_intent.status == StripeIntentStatus::PROCESSING
      else
        raise "Expected purchase #{purchase.id} to have either a processor_payment_intent_id or processor_setup_intent_id present"
      end
    end
  end

  private
    def cancel_charge_intent
      purchase.cancel_charge_intent!
    rescue ChargeProcessorError
      charge_intent = ChargeProcessor.get_charge_intent(purchase.merchant_account, purchase.processor_payment_intent_id)

      # Ignore the error if:
      # - charge intent succeeded (user completed SCA in the meanwhile)
      # - charge intent has been cancelled (by a parallel purchase)
      # In both these cases the purchase will transition to a successful or failed state.
      #
      # Raise all other (unexpected) errors.
      raise unless charge_intent&.succeeded? || charge_intent&.canceled?
    end

    def cancel_setup_intent
      purchase.cancel_setup_intent!
    rescue ChargeProcessorError
      setup_intent = ChargeProcessor.get_setup_intent(purchase.merchant_account, purchase.processor_setup_intent_id)

      # Ignore the error if:
      # - setup intent succeeded (user completed SCA in the meanwhile)
      # - setup intent has been cancelled (by a parallel purchase)
      # In both these cases the purchase will transition to a successful or failed state.
      #
      # Raise all other (unexpected) errors.
      raise unless setup_intent&.succeeded? || setup_intent&.canceled?
    end
end
