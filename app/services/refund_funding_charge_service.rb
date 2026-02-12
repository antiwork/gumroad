# frozen_string_literal: true

class RefundFundingChargeService
  include CurrencyHelper

  MINIMUM_CHARGE_CENTS = 100
  MAXIMUM_CHARGE_CENTS = 1_000_000

  Result = Struct.new(:success?, :credit, :error_message, keyword_init: true)

  def initialize(user:, amount_cents:, purchase:)
    @user = user
    @amount_cents = amount_cents
    @purchase = purchase
    @credit_card = user.refund_funding_credit_card
  end

  def perform
    return error("No backup payment method configured.") if @credit_card.blank?
    return error("Amount must be at least #{formatted_dollar_amount(MINIMUM_CHARGE_CENTS)}.") if @amount_cents < MINIMUM_CHARGE_CENTS
    return error("Amount cannot exceed #{formatted_dollar_amount(MAXIMUM_CHARGE_CENTS)}.") if @amount_cents > MAXIMUM_CHARGE_CENTS

    charge_result = charge_credit_card
    return error(charge_result[:error]) if charge_result[:error].present?

    credit = Credit.create_for_refund_funding!(
      user: @user,
      amount_cents: @amount_cents,
      purchase: @purchase,
      credit_card: @credit_card,
      processor_transaction_id: charge_result[:charge_id],
      processor_payment_intent_id: charge_result[:payment_intent_id]
    )

    Result.new(success?: true, credit:)
  rescue StandardError => e
    Bugsnag.notify(e)
    Rails.logger.error("RefundFundingChargeService error: #{e.message}")
    error("An unexpected error occurred while processing your backup card charge.")
  end

  def reverse_charge!(payment_intent_id)
    Stripe::Refund.create({ payment_intent: payment_intent_id })
  rescue Stripe::StripeError => e
    Bugsnag.notify(e)
    Rails.logger.error("RefundFundingChargeService reversal failed: #{e.message}")
  end

  private
    def charge_credit_card
      payment_intent = Stripe::PaymentIntent.create(
        {
          amount: @amount_cents,
          currency: "usd",
          customer: @credit_card.stripe_customer_id,
          payment_method: @credit_card.processor_payment_method_id,
          off_session: true,
          confirm: true,
          description: "Gumroad refund funding charge",
          metadata: {
            user_id: @user.id,
            user_email: @user.email,
            purchase_id: @purchase.id,
            type: "refund_funding"
          }
        },
        { idempotency_key: idempotency_key }
      )

      if payment_intent.status == "succeeded"
        {
          payment_intent_id: payment_intent.id,
          charge_id: payment_intent.latest_charge
        }
      elsif payment_intent.status == "requires_action"
        { error: "Your backup card requires additional authentication (3D Secure). Please update your backup payment method with a card that supports automatic off-session payments." }
      else
        { error: "Payment was not successful. Status: #{payment_intent.status}" }
      end
    rescue Stripe::CardError => e
      { error: e.message }
    rescue Stripe::InvalidRequestError => e
      Bugsnag.notify(e)
      { error: "Invalid payment request." }
    rescue Stripe::StripeError => e
      Bugsnag.notify(e)
      { error: "Payment processor error. Please try again." }
    end

    def idempotency_key
      "refund_funding_#{@user.id}_#{@purchase.id}"
    end

    def error(message)
      Result.new(success?: false, error_message: message)
    end
end
