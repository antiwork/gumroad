# frozen_string_literal: true

module ChargeProcessable
  def stripe_charge_processor?
    charge_processor_id == StripeChargeProcessor.charge_processor_id
  end

  def paypal_charge_processor?
    charge_processor_id == PaypalChargeProcessor.charge_processor_id
  end

  def braintree_charge_processor?
    charge_processor_id == BraintreeChargeProcessor.charge_processor_id
  end
end
