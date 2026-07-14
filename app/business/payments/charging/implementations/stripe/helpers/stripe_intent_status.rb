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
  # without finishing the Cash App QR flow — so it is not an error worth alerting on.
  CLIENT_HANDLED_ACTION_TYPES = ["cashapp_handle_redirect_or_display_qr_code"].freeze
end
