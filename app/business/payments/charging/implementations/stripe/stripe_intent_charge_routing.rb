# frozen_string_literal: true

# Canonical connect/destination/platform fee routing for a Stripe PaymentIntent:
# a connected (direct-charge) account collects an application fee on its own account; a
# Gumroad-managed account takes a destination transfer; the platform account keeps everything.
#
# Client-confirm checkout uses this helper; server-confirm keeps its parameter assembly inline but
# shares this validation so neither route asks Stripe to create an invalid seller payout.
module StripeIntentChargeRouting
  module_function

  MINIMUM_DIRECT_CHARGE_SELLER_PROCEEDS_CENTS = 0
  MINIMUM_DESTINATION_TRANSFER_AMOUNT_CENTS = 1
  SELLER_PROCEEDS_ERROR_MESSAGE = "The purchase total is too small for us to process. Please add another item to your order or contact the creator."

  # Direct charge is checked first because a connected account also has a user.
  def fee_params(merchant_account:, amount_cents:, amount_for_gumroad_cents:, currency:, reference:)
    if direct_charge_account?(merchant_account)
      ensure_charge_processor_merchant_id!(merchant_account)
      validate_seller_proceeds!(merchant_account:, amount_cents:, amount_for_gumroad_cents:, currency:, reference:)
      { application_fee_amount: amount_for_gumroad_cents }
    elsif destination_charge_account?(merchant_account)
      ensure_charge_processor_merchant_id!(merchant_account)
      validate_seller_proceeds!(merchant_account:, amount_cents:, amount_for_gumroad_cents:, currency:, reference:)
      { transfer_data: { destination: merchant_account.charge_processor_merchant_id, amount: amount_cents - amount_for_gumroad_cents } }
    else
      {}
    end
  end

  def request_options(merchant_account:, idempotency_key:)
    options = { idempotency_key: }
    options[:stripe_account] = merchant_account.charge_processor_merchant_id if direct_charge_account?(merchant_account)
    options
  end

  def direct_charge_account?(merchant_account)
    merchant_account&.is_a_stripe_connect_account?
  end

  def destination_charge_account?(merchant_account)
    merchant_account&.user.present?
  end

  def ensure_charge_processor_merchant_id!(merchant_account)
    return if merchant_account.charge_processor_merchant_id.present?
    raise "Merchant Account #{merchant_account.external_id} assigned to user #{merchant_account.user&.external_id} " \
          "but has no Charge Processor Merchant ID."
  end

  # Stripe permits a direct charge to collect an application fee equal to the full payment, but
  # a destination charge must transfer at least one subunit. Keeping the route-specific lower
  # bounds here prevents client-confirm and server-confirm checkout from drifting apart again.
  #
  # `amount_cents` and `amount_for_gumroad_cents` arrive in the PaymentIntent's own currency,
  # which for a buyer-currency (presentment) charge is the buyer's currency, not US dollars.
  # That is fine here only because the floors this compares against are counts of subunits
  # rather than money: "at least one subunit" means one yen or one euro cent depending on the
  # intent, and either reading is the correct one. If a future floor is ever expressed as a
  # real amount — say a minimum of fifty US cents — it will have to be converted into the
  # intent's currency first, because these arguments are not dollars.
  def validate_seller_proceeds!(merchant_account:, amount_cents:, amount_for_gumroad_cents:, currency:, reference:)
    minimum_seller_proceeds_cents = if direct_charge_account?(merchant_account)
      MINIMUM_DIRECT_CHARGE_SELLER_PROCEEDS_CENTS
    elsif destination_charge_account?(merchant_account)
      MINIMUM_DESTINATION_TRANSFER_AMOUNT_CENTS
    else
      return
    end

    seller_amount_cents = amount_cents - amount_for_gumroad_cents
    return if seller_amount_cents >= minimum_seller_proceeds_cents

    ErrorNotifier.notify(
      "Charge rejected before Stripe submit: seller proceeds would be non-positive",
      reference:,
      charge_amount_cents: amount_cents,
      gumroad_amount_cents: amount_for_gumroad_cents,
      seller_amount_cents:,
      currency:
    )
    raise ChargeProcessorCardError.new(PurchaseErrorCode::NET_NEGATIVE_SELLER_REVENUE, SELLER_PROCEEDS_ERROR_MESSAGE)
  end
end
