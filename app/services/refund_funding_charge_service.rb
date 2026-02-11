# frozen_string_literal: true

class RefundFundingChargeService
  include CurrencyHelper

  MINIMUM_CHARGE_CENTS = 100
  MAXIMUM_CHARGE_CENTS = 1_000_000

  Result = Struct.new(:success?, :credit, :error_message, :payment_intent_id, keyword_init: true)

  def initialize(user:, amount_cents:, purchase:)
    @user = user
    @amount_cents = amount_cents
    @purchase = purchase
    @credit_card = user.refund_funding_credit_card
  end

  def perform
    return error("No backup payment method configured.") if credit_card.blank?
    return error("Amount must be at least #{formatted_dollar_amount(MINIMUM_CHARGE_CENTS)}.") if amount_cents < MINIMUM_CHARGE_CENTS
    return error("Amount cannot exceed #{formatted_dollar_amount(MAXIMUM_CHARGE_CENTS)}.") if amount_cents > MAXIMUM_CHARGE_CENTS

    charge_result = charge_credit_card
    return error(charge_result[:error]) if charge_result[:error].present?

    credit = create_credit(charge_result)

    Result.new(success?: true, credit:, payment_intent_id: charge_result[:payment_intent_id])
  rescue StandardError => e
    Bugsnag.notify(e)
    Rails.logger.error("RefundFundingChargeService error: #{e.message}")
    error("An unexpected error occurred while processing your backup card charge.")
  end

  def self.reverse_charge!(payment_intent_id:)
    Stripe::Refund.create({ payment_intent: payment_intent_id })
  rescue Stripe::StripeError => e
    Bugsnag.notify(e)
    Rails.logger.error("Failed to reverse refund funding charge #{payment_intent_id}: #{e.message}")
  end

  private

  attr_reader :user, :amount_cents, :purchase, :credit_card

  def charge_credit_card
    payment_intent = Stripe::PaymentIntent.create(
      {
        amount: amount_cents,
        currency: Currency::USD,
        customer: credit_card.stripe_customer_id,
        payment_method: credit_card.processor_payment_method_id,
        off_session: true,
        confirm: true,
        description: "Gumroad refund funding charge",
        metadata: {
          user_id: user.id,
          user_email: user.email,
          purchase_id: purchase.id,
          type: "refund_funding"
        }
      },
      { idempotency_key: "refund_funding_#{user.id}_#{purchase.id}" }
    )

    if payment_intent.status == "succeeded"
      {
        success: true,
        payment_intent_id: payment_intent.id,
        charge_id: payment_intent.latest_charge
      }
    elsif payment_intent.status == "requires_action"
      { success: false, error: "Your backup card requires additional authentication (3D Secure) and cannot be charged automatically. Please update your backup payment method with a card that does not require 3D Secure verification." }
    else
      { success: false, error: "Payment was not successful. Please try again or update your backup payment method." }
    end
  rescue Stripe::CardError => e
    { success: false, error: e.message }
  rescue Stripe::InvalidRequestError => e
    Bugsnag.notify(e)
    { success: false, error: "Invalid payment request." }
  rescue Stripe::StripeError => e
    Bugsnag.notify(e)
    { success: false, error: "Payment processor error. Please try again." }
  end

  def create_credit(charge_result)
    Credit.create_for_refund_funding!(
      user:,
      amount_cents:,
      purchase:,
      credit_card:,
      processor_transaction_id: charge_result[:charge_id],
      processor_payment_intent_id: charge_result[:payment_intent_id]
    )
  end

  def error(message)
    Result.new(success?: false, error_message: message)
  end
end
