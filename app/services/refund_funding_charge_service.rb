# frozen_string_literal: true

class RefundFundingChargeService
  include CurrencyHelper

  MINIMUM_CHARGE_CENTS = 50 # Stripe minimum

  def initialize(user:, amount_cents:)
    @user = user
    @amount_cents = [amount_cents, MINIMUM_CHARGE_CENTS].max
    @credit_card = user.refund_funding_credit_card
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
        create_credit_for_user(payment_intent)
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

  def create_credit_for_user(payment_intent)
    # Use existing credit pattern with GUMROAD_ADMIN_ID as crediting_user
    # Store stripe charge id in json_data for audit trail
    credit = Credit.new
    credit.user = @user
    credit.merchant_account = MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id)
    credit.amount_cents = @amount_cents
    credit.crediting_user = User.find(GUMROAD_ADMIN_ID)
    credit.json_data = { refund_funding_stripe_charge_id: payment_intent.latest_charge }
    credit.save!

    balance_transaction_amount = BalanceTransaction::Amount.new(
      currency: Currency::USD,
      gross_cents: @amount_cents,
      net_cents: @amount_cents
    )
    balance_transaction = BalanceTransaction.create!(
      user: @user,
      merchant_account: credit.merchant_account,
      credit:,
      issued_amount: balance_transaction_amount,
      holding_amount: balance_transaction_amount
    )

    credit.balance = balance_transaction.balance
    credit.save!

    # Add comment for audit trail
    @user.comments.create(
      author_name: "Refund Funding Top-up",
      content: "Balance topped up by #{formatted_dollar_amount(@amount_cents)} to cover refund shortfall.",
      comment_type: :credit
    )

    credit
  end

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
