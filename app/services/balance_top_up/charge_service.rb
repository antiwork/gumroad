# frozen_string_literal: true

class BalanceTopUp::ChargeService
  include CurrencyHelper

  MINIMUM_TOP_UP_AMOUNT_CENTS = 100
  MAXIMUM_TOP_UP_AMOUNT_CENTS = 1_000_000

  Result = Struct.new(:success?, :balance_top_up, :error_message, keyword_init: true)

  def initialize(user:, amount_cents:, credit_card: nil, purchase: nil)
    @user = user
    @amount_cents = amount_cents
    @credit_card = credit_card || user.refund_funding_credit_card
    @purchase = purchase
  end

  def perform
    return validation_error("No credit card configured for balance funding.") if @credit_card.blank?
    return validation_error("Amount must be at least #{formatted_dollar_amount(MINIMUM_TOP_UP_AMOUNT_CENTS)}.") if @amount_cents < MINIMUM_TOP_UP_AMOUNT_CENTS
    return validation_error("Amount cannot exceed #{formatted_dollar_amount(MAXIMUM_TOP_UP_AMOUNT_CENTS)}.") if @amount_cents > MAXIMUM_TOP_UP_AMOUNT_CENTS

    balance_top_up = create_balance_top_up
    charge_result = charge_credit_card(balance_top_up)

    if charge_result[:success]
      complete_top_up(balance_top_up, charge_result)
    else
      fail_top_up(balance_top_up, charge_result[:error_message])
    end
  rescue StandardError => e
    Rails.logger.error("BalanceTopUp::ChargeService error: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
    Result.new(success?: false, error_message: "An unexpected error occurred while processing your balance top-up.")
  end

  private

  def create_balance_top_up
    BalanceTopUp.create!(
      user: @user,
      credit_card: @credit_card,
      purchase: @purchase,
      amount_cents: @amount_cents,
      processor: StripeChargeProcessor.charge_processor_id,
      state: "pending"
    )
  end

  def charge_credit_card(balance_top_up)
    balance_top_up.mark_processing!

    payment_intent = Stripe::PaymentIntent.create(
      {
        amount: @amount_cents,
        currency: "usd",
        customer: @credit_card.stripe_customer_id,
        payment_method: @credit_card.processor_payment_method_id,
        off_session: true,
        confirm: true,
        description: "Gumroad Balance Top-Up for refund coverage",
        metadata: {
          balance_top_up_id: balance_top_up.id,
          user_id: @user.id,
          user_email: @user.email
        }
      },
      { idempotency_key: "balance_top_up_#{balance_top_up.id}" }
    )

    if payment_intent.status == "succeeded"
      {
        success: true,
        payment_intent_id: payment_intent.id,
        charge_id: payment_intent.latest_charge
      }
    else
      { success: false, error_message: "Payment was not successful. Status: #{payment_intent.status}" }
    end
  rescue Stripe::CardError => e
    { success: false, error_message: e.message }
  rescue Stripe::InvalidRequestError => e
    { success: false, error_message: "Invalid request: #{e.message}" }
  rescue Stripe::StripeError => e
    { success: false, error_message: "Payment processor error: #{e.message}" }
  end

  def complete_top_up(balance_top_up, charge_result)
    ActiveRecord::Base.transaction do
      balance_top_up.update!(
        processor_payment_intent_id: charge_result[:payment_intent_id],
        processor_transaction_id: charge_result[:charge_id]
      )

      credit = create_credit_for_top_up(balance_top_up)
      balance_top_up.update!(credit:)
      balance_top_up.mark_successful!

      send_top_up_notification(balance_top_up)
    end

    Result.new(success?: true, balance_top_up:)
  end

  def fail_top_up(balance_top_up, error_message)
    balance_top_up.update!(error_message:)
    balance_top_up.mark_failed!

    Result.new(success?: false, balance_top_up:, error_message:)
  end

  def create_credit_for_top_up(balance_top_up)
    Credit.create_for_balance_top_up!(
      user: @user,
      amount_cents: @amount_cents,
      balance_top_up:
    )
  end

  def send_top_up_notification(balance_top_up)
    BalanceTopUpNotificationJob.perform_async(balance_top_up.id)
  end

  def validation_error(message)
    Result.new(success?: false, error_message: message)
  end
end
