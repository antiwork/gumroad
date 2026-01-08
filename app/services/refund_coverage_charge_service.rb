# frozen_string_literal: true

class RefundCoverageChargeService
  Result = Struct.new(:charge_intent, :error_message, keyword_init: true) do
    def success?
      charge_intent.present? && error_message.blank?
    end
  end

  def initialize(user:, purchase:, amount_cents:)
    @user = user
    @purchase = purchase
    @amount_cents = amount_cents
  end

  def perform
    credit_card = user.refund_credit_card
    if credit_card.blank?
      return Result.new(error_message: "Your balance is insufficient to process this refund. Add a refund coverage card in Settings > Payments to continue.")
    end
    return Result.new(error_message: "Please update your refund coverage card in Settings > Payments to continue.") unless credit_card.stripe_charge_processor?

    chargeable = credit_card.to_chargeable(merchant_account: gumroad_merchant_account)
    charge_intent = ChargeProcessor.create_payment_intent_or_charge!(
      gumroad_merchant_account,
      chargeable,
      amount_cents,
      amount_cents,
      reference,
      description,
      statement_description: "Refund coverage",
      off_session: true
    )

    return Result.new(error_message: "There is a temporary problem, please try again (your card was not charged).") if charge_intent.blank?
    if charge_intent.requires_action? || (charge_intent.is_a?(StripeChargeIntent) && charge_intent.processing?)
      return Result.new(error_message: "Your refund coverage card needs additional authentication. Please update it in Settings > Payments.")
    end
    return Result.new(error_message: "We couldn't charge your refund coverage card. Please try again.") unless charge_intent.succeeded?

    Result.new(charge_intent:)
  rescue ChargeProcessorCardError => e
    Result.new(error_message: PurchaseErrorCode.customer_error_message(e.message))
  rescue ChargeProcessorInvalidRequestError, ChargeProcessorUnavailableError, ChargeProcessorErrorRateLimit, ChargeProcessorErrorGeneric => e
    logger.error("Refund coverage charge failed for purchase #{purchase.id}: #{e.message}")
    Result.new(error_message: "There is a temporary problem, please try again (your card was not charged).")
  end

  private
    attr_reader :user, :purchase, :amount_cents

    def gumroad_merchant_account
      MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id)
    end

    def reference
      "refund-coverage-#{purchase.external_id}"
    end

    def description
      "Refund coverage for purchase #{purchase.external_id}"
    end
end
