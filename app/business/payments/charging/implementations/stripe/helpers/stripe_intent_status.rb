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
  # follow the redirect. It is therefore only treated as expected when the payment method the
  # buyer actually attempted is one of the client-redirect methods below (see
  # CLIENT_REDIRECT_PAYMENT_METHOD_TYPES); on any other intent it still raises the
  # unsupported-action alert.
  ACTION_TYPE_REDIRECT_TO_URL = "redirect_to_url"
  # Payment methods whose confirm happens client-side via stripe.confirmPayment, where
  # Stripe.js owns the full-page redirect to the provider's site and brings the buyer back on
  # our checkout return URL: the bank-redirect methods (iDEAL, Bancontact) plus the
  # buy-now-pay-later providers (Klarna, Afterpay/Clearpay, Affirm) and Cash App Pay (whose
  # mobile flow can redirect instead of showing the QR action type above). A retrieved intent
  # whose ATTEMPTED method is one of these can legitimately sit in requires_action +
  # redirect_to_url — e.g. the buyer abandoned iDEAL/Klarna on the provider's site and
  # revisited the return URL — so that combination is expected, not an error.
  # Server-confirmed flows (subscription renewals, off-session charges) only ever create
  # card/mandate intents, so they never carry these methods and keep alerting.
  CLIENT_REDIRECT_PAYMENT_METHOD_TYPES = %w[ideal bancontact klarna cashapp afterpay_clearpay affirm].freeze

  # True when a requires_action next_action of `type` is expected to be resolved by
  # Stripe.js in the buyer's browser, meaning the server should not alert on it. Shared by
  # StripeChargeIntent and StripeSetupIntent.
  #
  # For redirect_to_url the decision keys on the payment method the buyer actually attempted
  # (`payment_method_type`, from the intent's attached payment method) — never on the intent's
  # whole offered menu: a menu-based check would swallow a stray redirect on the dominant card
  # path whenever the intent merely OFFERED a redirect method alongside card, losing the alert
  # that pages on genuine misconfigurations. When the attempted type is unavailable (the
  # intent was retrieved without expanding payment_method, or none attached yet), fall back to
  # the offered menu so a legitimately-abandoned redirect doesn't page.
  def self.client_handled_next_action?(type, payment_method_types, payment_method_type: nil)
    return true if type.in?(CLIENT_HANDLED_ACTION_TYPES)
    return false unless type == ACTION_TYPE_REDIRECT_TO_URL

    if payment_method_type.present?
      payment_method_type.in?(CLIENT_REDIRECT_PAYMENT_METHOD_TYPES)
    else
      (Array(payment_method_types) & CLIENT_REDIRECT_PAYMENT_METHOD_TYPES).any?
    end
  end

  # The attempted payment method's type from an intent, when the API response carries it.
  # `payment_method` is an expandable field: a plain retrieve returns the ID string, an
  # expanded retrieve (or a fresh confirm response) returns the full object with `type`.
  # Uses [] access because Stripe::StripeObject raises on a missing attribute reader but
  # returns nil for an absent key.
  def self.attempted_payment_method_type(intent)
    payment_method = intent.try(:payment_method)
    return nil if payment_method.blank? || payment_method.is_a?(String)

    payment_method[:type]
  end
end
