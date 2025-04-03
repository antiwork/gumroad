# frozen_string_literal: true

# Represents the user's intent to pay. The intent may succeed immediately (resulting in a charge)
# or require additional confirmation from the user (such as 3D Secure).
#
# This is mainly a wrapper around Stripe's PaymentIntent API: https://stripe.com/docs/payments/payment-intents
#
# For other charge-based APIs (PayPal, Braintree) that don't have this notion of "intent" - and result in an
# immediate charge - we wrap the `charge` object in a `ChargeIntent` and set `succeeded` to `true` immediately.
class ChargeIntent
  attr_accessor :id, :payment_intent, :charge, :client_secret

  def requires_action?
    false
  end

  def succeeded?
    true
  end

  def canceled?
    false
  end
end
