# frozen_string_literal: true

# Public: A chargeable contains multiple internal chargeables that are mapped to charge processor implementations.
# Externally to the charging module the application interacts with the Chargeable only but internally to the individual
# chargeables associated with each charge processor are used to retrieve information about the chargeable and perform
# charges, refunds, etc.
class Chargeable
  def initialize(chargeables)
    @chargeables = {}
    chargeables.each do |chargeable|
      @chargeables[chargeable.charge_processor_id] = chargeable
    end
  end

  def charge_processor_ids
    @chargeables.keys
  end

  def charge_processor_id
    charge_processor_ids.join(",")
  end

  def prepare!
    @chargeables.values.first.prepare!
  end

  def fingerprint
    @chargeables.values.first.fingerprint
  end

  def funding_type
    @chargeables.values.first.funding_type
  end

  def last4
    @chargeables.values.first.last4
  end

  def number_length
    @chargeables.values.first.number_length
  end

  def visual
    @chargeables.values.first.visual
  end

  def expiry_month
    @chargeables.values.first.expiry_month
  end

  def expiry_year
    @chargeables.values.first.expiry_year
  end

  def zip_code
    @chargeables.values.first.zip_code
  end

  def card_type
    @chargeables.values.first.card_type
  end

  def country
    @chargeables.values.first.country
  end

  def payment_method_id
    @chargeables.values.first.payment_method_id
  end

  def stripe_setup_intent_id
    chargeable = @chargeables.values.first
    chargeable.respond_to?(:stripe_setup_intent_id) ? chargeable.stripe_setup_intent_id : nil
  end

  def stripe_payment_intent_id
    chargeable = @chargeables.values.first
    chargeable.respond_to?(:stripe_payment_intent_id) ? chargeable.stripe_payment_intent_id : nil
  end

  def reusable_token_for!(charge_processor_id, user)
    chargeable = get_chargeable_for(charge_processor_id)
    return chargeable.reusable_token!(user) if chargeable

    nil
  end

  def get_chargeable_for(charge_processor_id)
    @chargeables[charge_processor_id]
  end

  def can_be_saved?
    !get_chargeable_for(PaypalChargeProcessor.charge_processor_id).is_a?(PaypalApprovedOrderChargeable)
  end

  # Recurring payments in India via Stripe require e-mandates.
  # https://stripe.com/docs/india-recurring-payments?integration=paymentIntents-setupIntents
  def requires_mandate?
    @chargeables.values.first.respond_to?(:requires_mandate?) && @chargeables.values.first.requires_mandate?
  end
end
