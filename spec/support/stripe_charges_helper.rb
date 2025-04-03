# frozen_string_literal: true

module StripeChargesHelper
  def create_stripe_charge(payment_method_id, **charge_params)
    payment_intent = create_stripe_payment_intent(payment_method_id, **charge_params)

    Stripe::Charge.retrieve(id: payment_intent.latest_charge)
  end

  def create_stripe_payment_intent(payment_method_id, **charge_params)
    payload = {
      payment_method: payment_method_id,
      payment_method_types: ["card"]
    }
    payload.merge!(charge_params)

    Stripe::PaymentIntent.create(payload)
  end

  def create_stripe_setup_intent(payment_method_id, **charge_params)
    stripe_customer = Stripe::Customer.create(payment_method: payment_method_id)

    payload = {
      payment_method: payment_method_id,
      customer: stripe_customer.id,
      payment_method_types: ["card"],
      usage: "off_session"
    }
    payload.merge!(charge_params)

    Stripe::SetupIntent.create(payload)
  end
end
