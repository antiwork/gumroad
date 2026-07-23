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
  # The generic browser-redirect action. Unlike the Cash App action type above it is not
  # method-specific: many payment methods can surface it, including ones a server-confirmed
  # (off-session) intent might carry by misconfiguration, where no Stripe.js client exists to
  # follow the redirect. It is therefore only treated as expected when the intent actually
  # lists one of the client-redirect methods below (see CLIENT_REDIRECT_PAYMENT_METHOD_TYPES);
  # on any other intent it still raises the unsupported-action alert.
  ACTION_TYPE_REDIRECT_TO_URL = "redirect_to_url"
  # Payment methods whose confirm happens client-side via stripe.confirmPayment, where
  # Stripe.js owns the redirect to the provider's site (the Phase 3 redirect methods, #5741,
  # plus Klarna from its launch). A retrieved intent listing one of these can legitimately sit
  # in requires_action + redirect_to_url — e.g. the buyer abandoned iDEAL/Klarna on the
  # provider's site and revisited the return URL — so that combination is expected, not an
  # error. Server-confirmed flows (subscription renewals, off-session charges) only ever
  # create card/mandate intents, so they never list these methods and keep alerting.
  CLIENT_REDIRECT_PAYMENT_METHOD_TYPES = %w[ideal bancontact klarna cashapp afterpay_clearpay affirm].freeze

  # True when a requires_action next_action of `type` is expected to be resolved by
  # Stripe.js in the buyer's browser for an intent listing `payment_method_types`, meaning
  # the server should not alert on it. Shared by StripeChargeIntent and StripeSetupIntent.
  def self.client_handled_next_action?(type, payment_method_types)
    return true if type.in?(CLIENT_HANDLED_ACTION_TYPES)

    type == ACTION_TYPE_REDIRECT_TO_URL &&
      (Array(payment_method_types) & CLIENT_REDIRECT_PAYMENT_METHOD_TYPES).any?
  end
end
