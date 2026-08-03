# frozen_string_literal: true

class StripeIntentStatus
  SUCCESS = "succeeded"
  REQUIRES_PAYMENT_METHOD = "requires_payment_method"
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
  # alipay_handle_redirect is Alipay's own method-specific action type: Stripe.js performs the
  # full-page redirect to Alipay itself, so seeing it on a retrieved intent means the buyer has
  # not finished (or has abandoned) the redirect — expected, not an error worth alerting on.
  # Pix behaves the same way for a different mechanic: Stripe.js renders the Pix QR code and
  # copy-paste key, the buyer pays in their own banking app, and the intent sits in
  # requires_action until they do (or until the key expires), so a buyer who reopens the return
  # page mid-flow is a normal state rather than a misconfiguration.
  # Stripe.js owns UPI's redirect/QR action, but its on-session result is immediate, unlike Pix.
  CLIENT_HANDLED_ACTION_TYPES = ["cashapp_handle_redirect_or_display_qr_code", "alipay_handle_redirect", "pix_display_qr_code", "upi_handle_redirect_or_display_qr_code"].freeze
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
  # Alipay is included because Stripe can surface either the generic redirect_to_url action or
  # its own alipay_handle_redirect type above, depending on the confirm; both are client-owned.
  CLIENT_REDIRECT_PAYMENT_METHOD_TYPES = %w[ideal bancontact klarna cashapp afterpay_clearpay affirm alipay].freeze
  # Next-action types meaning "the buyer must now go and pay somewhere else": Stripe.js showed a QR
  # code / copy-paste key, and the buyer pays in their own banking app (Pix). The intent
  # legitimately stays in requires_action until they do, or until the key expires — so the browser
  # finishing its confirm call is NOT evidence the payment failed. Finalizers must leave such a
  # purchase in progress and report it as pending (see Purchase::FinalizeConfirmedChargeService);
  # the payment_intent.succeeded / payment_intent.payment_failed webhooks decide the real outcome.
  # Cash App Pay's QR action is deliberately NOT here: its QR is scanned during checkout and
  # resolves in the same session, so a returning confirm really does mean the buyer gave up.
  ASYNCHRONOUS_CUSTOMER_INITIATED_ACTION_TYPES = ["pix_display_qr_code"].freeze

  # Sentinel returned by attempted_payment_method_type when a payment method IS attached but
  # the lookup failed (Stripe error after retries). It is deliberately distinct from nil ("no
  # method attached"): nil falls back to the offered-menu heuristic, while a failed lookup
  # must NOT — cashapp sits in both LAUNCHED and client-redirect sets, so the menu fallback
  # would swallow a stray redirect on essentially every US intent, silencing the
  # misconfiguration alert exactly during a Stripe outage (the only time this fires, given
  # max_network_retries). Better a rare duplicate page for an abandoned redirect than a dead
  # alert.
  PAYMENT_METHOD_LOOKUP_FAILED = :payment_method_lookup_failed

  # True when a requires_action next_action of `type` is expected to be resolved by
  # Stripe.js in the buyer's browser, meaning the server should not alert on it. Shared by
  # StripeChargeIntent and StripeSetupIntent.
  #
  # For redirect_to_url the decision keys on the payment method the buyer actually attempted
  # (`payment_method_type`, from the intent's attached payment method) — never on the intent's
  # whole offered menu: a menu-based check would swallow a stray redirect on the dominant card
  # path whenever the intent merely OFFERED a redirect method alongside card, losing the alert
  # that pages on genuine misconfigurations. When the attempted type is unavailable because
  # nothing is attached yet (or the intent wasn't expanded and carried no ID), fall back to
  # the offered menu so a legitimately-abandoned redirect doesn't page. When the type is
  # unavailable because the LOOKUP FAILED (see PAYMENT_METHOD_LOOKUP_FAILED), keep alerting —
  # a failure is not evidence the redirect was client-owned.
  def self.client_handled_next_action?(type, payment_method_types, payment_method_type: nil)
    return true if type.in?(CLIENT_HANDLED_ACTION_TYPES)
    return false unless type == ACTION_TYPE_REDIRECT_TO_URL
    return false if payment_method_type == PAYMENT_METHOD_LOOKUP_FAILED

    if payment_method_type.present?
      payment_method_type.in?(CLIENT_REDIRECT_PAYMENT_METHOD_TYPES)
    else
      (Array(payment_method_types) & CLIENT_REDIRECT_PAYMENT_METHOD_TYPES).any?
    end
  end

  # The attempted payment method's type from an intent. A fresh confirm response carries the
  # full payment method object inline; a plain retrieve (the checkout return path, the
  # abandonment sweeper) returns only the ID string. In that case we make one targeted
  # PaymentMethod retrieve — this only ever runs on the rare requires_action +
  # redirect_to_url combination, so it adds no API traffic to the normal charge paths.
  # `stripe_account` scopes the lookup for direct-Connect merchants (payment methods created
  # on a connected account are not visible from the platform). Returns nil when nothing is
  # attached (callers then fall back to the intent's offered menu) and
  # PAYMENT_METHOD_LOOKUP_FAILED when a method IS attached but the retrieve failed — the two
  # cases must stay distinguishable so a lookup failure keeps the stray-redirect alert alive
  # instead of silently degrading to the menu heuristic (see the sentinel's comment). The
  # failure itself is also reported: with the client's retries exhausted it usually means a
  # Stripe incident, which is worth knowing about in its own right.
  # Uses [] access because Stripe::StripeObject raises on a missing attribute reader but
  # returns nil for an absent key.
  def self.attempted_payment_method_type(intent, stripe_account: nil)
    payment_method = intent.try(:payment_method)
    return nil if payment_method.blank?

    if payment_method.is_a?(String)
      begin
        payment_method = Stripe::PaymentMethod.retrieve(payment_method, { stripe_account: }.compact)
      rescue Stripe::StripeError => e
        ErrorNotifier.notify(e, payment_method_id: payment_method, stripe_account:)
        return PAYMENT_METHOD_LOOKUP_FAILED
      end
    end

    payment_method[:type]
  end
end
