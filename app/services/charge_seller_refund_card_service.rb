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
      charge_intent = create_stripe_charge(charge_amount)

      if charge_intent.succeeded?
        if charge_intent.charge&.status == 'succeeded'
          success(charge_amount)
        else
          failure("Stripe charge failed: charge status was #{charge_intent.charge&.status || 'unknown'}")
        end
      else
        error_message = if charge_intent.is_a?(StripeChargeIntent) && charge_intent.payment_intent&.last_payment_error
          charge_intent.payment_intent.last_payment_error.message
        else
          "Charge intent did not succeed"
        end
        failure("Stripe charge failed: #{error_message}")
      end
    rescue ChargeProcessorInvalidRequestError, ChargeProcessorCardError, ChargeProcessorError => e
      failure("Stripe error: #{e.message}")
    rescue => e
      failure("Unexpected error: #{e.message}")
    end
  end

  def create_stripe_charge(amount)
    refund_card = seller.refund_credit_card

    raise Stripe::InvalidRequestError.new("Refund card payment method ID not found", nil) if refund_card.processor_payment_method_id.blank?

    merchant_account = MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id)
    raise "Gumroad merchant account not found" if merchant_account.nil?

    chargeable = refund_card.to_chargeable(merchant_account: merchant_account)
    chargeable.prepare!

    ChargeProcessor.create_payment_intent_or_charge!(
      merchant_account,
      chargeable,
      amount,
      amount,
      "refund-charge-#{seller.id}",
      "Refund payment method charge for seller #{seller.id}",
      off_session: true
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
