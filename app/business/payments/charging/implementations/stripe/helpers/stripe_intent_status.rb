# frozen_string_literal: true

class StripeIntentStatus
  SUCCESS = "succeeded"
  REQUIRES_CONFIRMATION = "requires_confirmation"
  REQUIRES_ACTION = "requires_action"
  PROCESSING = "processing"
  CANCELED = "canceled"
  ACTION_TYPE_USE_SDK = "use_stripe_sdk"

  # Next-action types that Stripe.js resolves entirely in the buyer's browser on the
  # client-confirmed checkout path (the browser calls stripe.confirmPayment and Stripe.js
  # shows the QR code / performs the redirect itself). Seeing one of these on a retrieved
  # intent is expected — for example, a buyer who returns to the checkout return page
  # without finishing the Cash App QR flow, or who revisits the return URL after abandoning
  # a redirect method (iDEAL, Klarna) on the provider's site — so it is not an error worth
  # alerting on. redirect_to_url joined the list with Klarna's launch: since the Phase 3
  # redirect methods (#5741), Stripe.js owns the redirect during confirmPayment, so the
  # server never needs to act on it.
  CLIENT_HANDLED_ACTION_TYPES = ["cashapp_handle_redirect_or_display_qr_code", "redirect_to_url"].freeze
end
