# frozen_string_literal: true

class RefundFundingChargeService
  include CurrencyHelper

  MINIMUM_CHARGE_CENTS = 50 # Stripe minimum

  def initialize(user:, amount_cents:, purchase: nil)
    @user = user
    @amount_cents = [amount_cents, MINIMUM_CHARGE_CENTS].max
    @credit_card = user.refund_funding_credit_card
    @purchase = purchase
  end

  def perform
    return { success: false, error: "No backup payment method configured." } if @credit_card.blank?

    begin
      payment_intent = Stripe::PaymentIntent.create(
        {
          amount: @amount_cents,
          currency: "usd",
          customer: @credit_card.stripe_customer_id,
          payment_method: @credit_card.processor_payment_method_id,
          off_session: true,
          confirm: true,
          description: "Gumroad refund funding top-up",
          metadata: {
            user_id: @user.id,
            user_email: @user.email,
            type: "refund_funding"
          }
        },
        { idempotency_key: "refund_funding_#{@user.id}_#{Time.current.to_i}" }
      )

      if payment_intent.status == "succeeded"
        credit = Credit.create_for_refund_funding!(
          user: @user,
          amount_cents: @amount_cents,
          refund_funding_purchase: @purchase,
          credit_card: @credit_card
        )
        credit.update!(json_data: { refund_funding_stripe_charge_id: payment_intent.latest_charge })
        send_confirmation_email
        { success: true, payment_intent_id: payment_intent.id }
      else
        { success: false, error: "Payment was not successful. Status: #{payment_intent.status}" }
      end
    rescue Stripe::CardError => e
      Rails.logger.error("RefundFundingChargeService card error: #{e.message}")
      { success: false, error: e.message }
    rescue Stripe::InvalidRequestError => e
      Rails.logger.error("RefundFundingChargeService invalid request: #{e.message}")
      { success: false, error: "Invalid payment request." }
    rescue Stripe::StripeError => e
      Rails.logger.error("RefundFundingChargeService error: #{e.message}")
      { success: false, error: "Payment processor error. Please try again." }
    end
  end

  private

  def send_confirmation_email
    CreatorMailer.refund_funding_charge_confirmation(
      seller: @user,
      amount_cents: @amount_cents,
      card_visual: @credit_card.visual
    ).deliver_later
  rescue StandardError => e
    # Don't fail the charge if email fails
    Rails.logger.error("RefundFundingChargeService email error: #{e.message}")
  end
end
