# frozen_string_literal: true

module ChargeProcessable
  def stripe_charge_processor?
    charge_processor_id == StripeChargeProcessor.charge_processor_id
  end
  alias_method :is_stripe_charge_processor, :stripe_charge_processor?

  def paypal_charge_processor?
    charge_processor_id == PaypalChargeProcessor.charge_processor_id
  end
  alias_method :is_paypal_charge_processor, :paypal_charge_processor?

  def braintree_charge_processor?
    charge_processor_id == BraintreeChargeProcessor.charge_processor_id
  end
  alias_method :is_braintree_charge_processor, :braintree_charge_processor?
end
