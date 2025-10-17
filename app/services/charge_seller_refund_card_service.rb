# frozen_string_literal: true

class ChargeSellerRefundCardService
  attr_reader :seller, :refund_amount_cents, :error_message

  def initialize(seller, refund_amount_cents)
    @seller = seller
    @refund_amount_cents = refund_amount_cents
    @error_message = nil
  end

  def call
    return failure("Seller has no refund credit card set") unless seller.refund_credit_card.present?

    available_balance = seller.unpaid_balance_cents
    return success(0) if available_balance >= refund_amount_cents

    charge_amount = refund_amount_cents - available_balance
    process_stripe_charge(charge_amount)
  end

  def success?
    @error_message.nil?
  end

  def charged_amount
    @charged_amount || 0
  end

  private

  def process_stripe_charge(charge_amount)
    begin
      # Use existing Stripe integration
      charge = create_stripe_charge(charge_amount)

      if charge.status == 'succeeded'
        success(charge_amount)
      else
        failure("Stripe charge failed: #{charge.failure_message}")
      end
    rescue Stripe::StripeError => e
      failure("Stripe error: #{e.message}")
    rescue => e
      failure("Unexpected error: #{e.message}")
    end
  end

  def create_stripe_charge(amount)
    Stripe::Charge.create(
      amount: amount,
      currency: 'usd',
      customer: seller.refund_credit_card.stripe_customer_id,
      source: seller.refund_credit_card.stripe_fingerprint,
      description: "Refund payment method charge for seller #{seller.id}"
    )
  end

  def success(charged_amount)
    @charged_amount = charged_amount
    self
  end

  def failure(message)
    @error_message = message
    self
  end
end
