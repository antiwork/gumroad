# frozen_string_literal: true

# Canonical connect/destination/platform fee routing for a Stripe PaymentIntent:
# a connected (direct-charge) account collects an application fee on its own account; a
# Gumroad-managed account takes a destination transfer; the platform account keeps everything.
#
# Client-confirm checkout uses this helper; the server-confirm path still inlines the same branch in
# StripeChargeProcessor#create_payment_intent_or_charge!, so keep the two in sync until it is moved.
module StripeIntentChargeRouting
  module_function

  # Direct charge is checked first because a connected account also has a user.
  def fee_params(merchant_account:, amount_cents:, amount_for_gumroad_cents:)
    if direct_charge_account?(merchant_account)
      ensure_charge_processor_merchant_id!(merchant_account)
      { application_fee_amount: amount_for_gumroad_cents }
    elsif destination_charge_account?(merchant_account)
      ensure_charge_processor_merchant_id!(merchant_account)
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
end
