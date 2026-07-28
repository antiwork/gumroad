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

  # True when the buyer still has an outstanding way to complete this payment away from our
  # checkout — today only Pix, where Stripe issued a QR code / copy-paste key the buyer pays in
  # their banking app. Non-Stripe processors charge immediately, so they never wait on the buyer.
  def awaiting_customer_initiated_payment?
    false
  end
end
