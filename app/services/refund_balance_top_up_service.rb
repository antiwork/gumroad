# frozen_string_literal: true

class RefundBalanceTopUpService
  MAX_ATTEMPTS = 2

  Result = Struct.new(:success?, :error_message, :charged_cents, :credited_cents, keyword_init: true)

  attr_reader :user, :purchase, :required_cents

  def initialize(user:, purchase:, required_cents:)
    @user = user
    @purchase = purchase
    @required_cents = required_cents
  end

  def ensure_funds
    attempts = 0

    while deficit_cents.positive?
      return failure("We couldn't add enough funds to cover this refund. Please check your backup payment method.") if attempts >= MAX_ATTEMPTS

      top_up_result = charge_and_credit!(deficit_cents)
      return top_up_result unless top_up_result.success?

      attempts += 1
      user.reload
    end

    Result.new(success?: true, credited_cents: 0, charged_cents: 0)
  end

  private
    def deficit_cents
      required_cents - user.unpaid_balance_cents
    end

    def charge_and_credit!(shortfall_cents)
      payment_method = user.refund_payment_method
      return failure("You need to add a backup payment method before issuing this refund.") if payment_method.blank? || payment_method.credit_card.blank?

      charge_amount_cents = charge_amount_for(shortfall_cents)

      chargeable = payment_method.credit_card.to_chargeable
      merchant_account = MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id)
      charge_intent = ChargeProcessor.create_payment_intent_or_charge!(
        merchant_account,
        chargeable,
        charge_amount_cents,
        charge_amount_cents,
        purchase.external_id,
        "Refund coverage top-up for purchase #{purchase.external_id}",
        metadata: {
          purchase_id: purchase.id,
          seller_id: user.id,
          context: "refund_balance_top_up"
        },
        off_session: true
      )

      return failure("Your backup payment method needs authentication. Please update it and try again.") if charge_intent.requires_action?
      return failure("We could not charge your backup payment method. Please update it and try again.") unless charge_intent.succeeded?

      credited_cents = charge_intent.charge.flow_of_funds.gumroad_amount.cents
      credit = Credit.create_for_credit!(user:, amount_cents: credited_cents, crediting_user: user)
      credit.json_data = (credit.json_data || {}).merge("refund_balance_top_up" => {
        "charge_id" => charge_intent.charge.id,
        "charge_processor_id" => charge_intent.charge.charge_processor_id,
        "charged_cents" => charge_amount_cents
      })
      credit.save!

      Result.new(success?: true, charged_cents: charge_amount_cents, credited_cents:)
    rescue ChargeProcessorCardError => e
      Result.new(success?: false, error_message: e.message)
    rescue ChargeProcessorInvalidRequestError, ChargeProcessorUnavailableError => e
      Bugsnag.notify(e)
      failure("Sorry, something went wrong while charging your backup payment method. Please try again.")
    end

    def charge_amount_for(shortfall_cents)
      percent = Purchase::PROCESSOR_FEE_PER_THOUSAND / 1000.0
      numerator = shortfall_cents + Purchase::PROCESSOR_FIXED_FEE_CENTS
      ((numerator / (1.0 - percent)).ceil).clamp(Purchase::PROCESSOR_FIXED_FEE_CENTS + 1, 1_000_000_00)
    end

    def failure(message)
      Result.new(success?: false, error_message: message)
    end
end
