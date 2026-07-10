# frozen_string_literal: true

# Server-authoritative policy boundary for the client-confirmed Intent path (Lane B). Given a cart's
# sellers and product lifecycle, it decides whether the cart may confirm client-side and which Stripe
# payment methods it may use. The frontend cannot widen this: payment_method_types is the intersection
# of the eligible set with a hardcoded launched set, so no client-supplied value can add a method.
#
# Two method sets are distinguished:
#   - eligible_payment_method_types: the policy set the cart *could* use (the eligibility-by-product-type
#     policy). This is the logged decision and what later units intersect with per-method launch/PPP gates.
#   - payment_method_types: what Stripe actually receives on the client-confirmed path today. Card and
#     Link are always launched (Link is inline and auto-enables with the Payment Element itself); the
#     US-locked first-launch methods (Cash App Pay, ACH Direct Debit) join for US buyers via the GeoIP
#     gate below.
#
# Handshake note: the deferred PaymentIntent's payment_method_types must equal the Payment Element's or
# Stripe rejects the ConfirmationToken (which is payment_method_types-scoped, so it also can't be
# confirmed against an automatic_payment_methods intent — hence an explicit array here, never
# automatic_payment_methods). Both sides read this resolver, but they derive its lifecycle inputs
# independently (the presenter from the cart, PreparePaymentIntentService from the persisted purchases).
# Both derive buyer_country from the same GeoIP basis (the presenter from the request ip, the service
# from the purchase's server-owned ip_country), so they resolve identical sets — and
# PreparePaymentIntentService hard-stops an ineligible cart before creating the intent, so any residual
# mismatch fails closed rather than reaching Stripe with the wrong method list.
class Checkout::PaymentMethodResolver
  # Buyer-present single-seller dynamic set. Apple Pay / Google Pay ride on "card" in the Payment
  # Element, so they are not separate types here. us_bank_account (ACH Direct Debit) is a
  # delayed-notification method: it settles asynchronously via the PaymentIntent webhook lifecycle.
  ONE_TIME_PAYMENT_METHOD_TYPES = %w[card link klarna afterpay_clearpay affirm ideal bancontact cashapp us_bank_account].freeze
  # Afterpay/Clearpay and Affirm are one-time, buyer-present only, so a recurring lifecycle drops them.
  RECURRING_INELIGIBLE_PAYMENT_METHOD_TYPES = %w[afterpay_clearpay affirm].freeze
  # Launched on the client-confirmed path: card everywhere; Link everywhere (inline — it rides
  # card's two-step confirm machinery with no return-page/webhook dependency, launched under the
  # element flags themselves since Stripe's dashboard payment-method settings are the emergency
  # kill switch, per-seller Flipper adds no useful lever); plus the US-locked first-launch methods
  # (region-gated below) — Cash App Pay (redirect; confirms via the #5664 return page) and ACH Direct
  # Debit (delayed-notification; settles via the PaymentIntent webhook lifecycle). The EUR methods
  # (iDEAL/Bancontact/SEPA) stay gated until buyer-currency FX lands.
  LAUNCHED_PAYMENT_METHOD_TYPES = %w[card link cashapp us_bank_account].freeze
  LINK_PAYMENT_METHOD_TYPE = "link"
  # Methods that only work for US buyers on USD PaymentIntents. ACH Direct Debit debits a US bank
  # account; Cash App Pay is US-locked. These are dropped from the launched set unless GeoIP ∈ {US}.
  US_LOCKED_PAYMENT_METHOD_TYPES = %w[us_bank_account cashapp].freeze
  US_ALPHA2 = "US"
  # PPP method matrix (U13). On a PPP-discounted checkout, only methods whose funding country is
  # verifiable pre-charge (card/wallets via card.country, and later sepa_debit.country) or whose
  # region lock matches the discount country (Cash App Pay / ACH are US-locked, so US-only) may be
  # offered. Methods with NO Stripe-owned funding country (Klarna/Afterpay/Affirm/PayPal/Link) are
  # gated out on PPP checkouts: their preview yields nil country, so a PPP purchase would always
  # fail closed at prepare — don't render a method that cannot complete.
  # sepa_debit is wired but dormant until SEPA launches post-FX.
  PPP_VERIFIABLE_PAYMENT_METHOD_TYPES = %w[card sepa_debit].freeze
  # US-locked methods double as region-locked entries: allowed on a PPP checkout only when the
  # buyer's (GeoIP) country — the basis of the discount — is the lock country. The resolver's US
  # region gate already enforces buyer_country == US for these, so on a PPP checkout they stay
  # offered exactly when the discount country is the lock country.
  PPP_REGION_LOCKED_PAYMENT_METHOD_TYPES = US_LOCKED_PAYMENT_METHOD_TYPES
  # Multi-seller and other Lane A carts keep Gumroad's existing card + PayPal set.
  LANE_A_PAYMENT_METHOD_TYPES = %w[card paypal].freeze

  Resolution = Data.define(:client_confirm_eligible, :payment_method_types, :eligible_payment_method_types, :fallback_reason, :stripe_connect_account_id) do
    def client_confirm_eligible? = client_confirm_eligible
  end

  # cart_product_currency: the ISO code (lowercase, e.g. "eur") the cart's single item is priced
  # in, or nil for multi-item carts / unknown. Only consulted by the test-mode forced-currency
  # gate below: a forced-currency method (iDEAL/Bancontact) is offered only when the cart is
  # priced in exactly the currency that method forces, because that is the only shape where the
  # Payment Element mounts in that currency (StripePaymentPresenter#method_forced_qa_shape?) and
  # the deferred intent can be created in it. Offering the methods on any other cart puts EUR-only
  # entries on a USD element/intent, which Stripe rejects outright (no element mounts at all).
  def initialize(sellers:, recurring: false, commission: false, setup_for_future: false, buyer_country: nil, ppp_discounted: false, cart_product_currency: nil)
    @sellers = sellers
    @recurring = recurring
    @commission = commission
    @setup_for_future = setup_for_future
    @buyer_country = buyer_country
    @ppp_discounted = ppp_discounted
    @cart_product_currency = cart_product_currency
  end

  def resolve
    @resolution ||= begin
      reason = ineligibility_reason
      eligible = eligible_method_policy
      resolution = Resolution.new(
        client_confirm_eligible: reason.nil?,
        # Nil on Lane A carts: they never mount the client-confirmed Payment Element, so there is no
        # Stripe method list to hand them. Non-nil only when the cart confirms client-side.
        payment_method_types: reason.nil? ? launched_method_set(eligible) : nil,
        eligible_payment_method_types: eligible,
        fallback_reason: reason,
        stripe_connect_account_id: reason.nil? ? stripe_connect_account_id : nil
      )
      log_decision(resolution)
      resolution
    end
  end

  private
    attr_reader :sellers, :recurring, :commission, :setup_for_future, :buyer_country, :ppp_discounted, :cart_product_currency

    # The client-confirm cart-shape gates (single-seller, non-connect, one-time), owned here and applied
    # as an ordered set of reasons so a blocked cart records *why* it stayed on Lane A.
    def ineligibility_reason
      return "multi_seller" unless sellers.one?
      return "direct_charge_account_unlinked" if direct_charge_seller? && stripe_connect_account_id.blank?
      return "recurring_charge" if recurring
      return "commission" if commission
      return "setup_flow" if setup_for_future
      nil
    end

    def direct_charge_seller?
      sellers.one? && sellers.first.has_stripe_account_connected?
    end

    def stripe_connect_account_id
      return nil unless direct_charge_seller?
      sellers.first.stripe_connect_account&.charge_processor_merchant_id
    end

    def eligible_method_policy
      return LANE_A_PAYMENT_METHOD_TYPES unless sellers.one?

      methods = ONE_TIME_PAYMENT_METHOD_TYPES
      methods -= RECURRING_INELIGIBLE_PAYMENT_METHOD_TYPES if recurring
      methods
    end

    # What Stripe actually receives: the eligible policy set intersected with the launched set, then
    # account-gated, then region-gated, then PPP-gated. A US-locked method (ACH, Cash App Pay) is only
    # offered when the buyer's GeoIP country is US, so a non-US buyer never sees a method they can't
    # complete. When the buyer country is unknown (nil), US-locked methods are dropped to fail safe.
    # Card always survives, and Link (inline, not US-locked) is unaffected by either gate.
    #
    # The account gate: on a direct-charge (Stripe Connect) seller, the PaymentIntent is created on
    # the SELLER's Stripe account, not Gumroad's platform account — and payment method capabilities
    # live per-account. Cash App Pay and ACH are activated on the platform account, but connected
    # accounts routinely lack them (non-US accounts can't have them at all, and even US connect
    # accounts usually haven't activated them in their own dashboard). Listing a method the account
    # doesn't have makes Stripe reject the intent create outright, which failed every US buyer's
    # checkout on those sellers with a misleading "stripe_unavailable" error — so only offer the
    # US-locked methods when the charge lands on the platform account, where we control activation.
    def launched_method_set(eligible)
      launched = eligible & LAUNCHED_PAYMENT_METHOD_TYPES
      launched += forced_currency_test_mode_methods(eligible)
      launched -= US_LOCKED_PAYMENT_METHOD_TYPES if buyer_country != US_ALPHA2 || direct_charge_seller?
      launched = ppp_method_matrix(launched) if ppp_discounted
      launched
    end

    # The EUR forced-currency methods (iDEAL/Bancontact) are not launched: they can only be offered
    # once buyer-currency presentment carries them, and the public launch is the #5362 cohort with
    # its own approval gate. But the presentment machinery needs real manual QA before that launch,
    # so surface them when ALL of these hold: the seller has the internal buyer-currency flags on,
    # Stripe is in test mode (preview apps / staging), and the cart's single item is priced in the
    # currency the method forces. The last condition mirrors the presenter's
    # method_forced_qa_shape? gate: only that cart shape mounts the Payment Element in the forced
    # currency, and a forced-currency method listed on a USD element/intent makes Stripe reject the
    # whole element session (no payment form renders at all — this broke flag-on sellers' plain USD
    # checkouts before the gate was added). Production sellers run live-mode Stripe keys, so this
    # branch can never add methods to a real checkout.
    def forced_currency_test_mode_methods(eligible)
      return [] unless Checkout::BuyerCurrencyEligibility.stripe_test_mode?
      return [] unless sellers.one? && Checkout::BuyerCurrencyEligibility.seller_enabled?(sellers.first)

      (eligible & Checkout::BuyerCurrencyEligibility::FORCED_CURRENCY_PAYMENT_METHODS.keys).select do |method|
        Checkout::BuyerCurrencyEligibility.forced_currency_for(method) == cart_product_currency
      end
    end

    # U13: a PPP-discounted checkout only offers methods the pre-charge country check can verify
    # (card/wallets, later sepa_debit) or whose region lock matches the buyer's country (Cash App
    # Pay / ACH — already region-gated above, so surviving entries match by construction). Methods
    # with no Stripe-owned funding country (Link today; Klarna/Afterpay/Affirm/PayPal when they
    # launch) are dropped: `previewed_country` would return nil and the purchase would fail closed
    # at prepare anyway — never render a method that cannot complete the discounted purchase.
    def ppp_method_matrix(launched)
      launched & (PPP_VERIFIABLE_PAYMENT_METHOD_TYPES + PPP_REGION_LOCKED_PAYMENT_METHOD_TYPES)
    end

    def log_decision(resolution)
      launch_gated_out = resolution.eligible_payment_method_types - Array(resolution.payment_method_types)
      Rails.logger.info(
        "[#{self.class.name}] client_confirm_eligible=#{resolution.client_confirm_eligible} " \
        "seller_ids=#{sellers.map { _1&.id }} recurring=#{recurring} commission=#{commission} " \
        "setup_for_future=#{setup_for_future} buyer_country=#{buyer_country.inspect} " \
        "ppp_discounted=#{ppp_discounted} " \
        "fallback_reason=#{resolution.fallback_reason.inspect} " \
        "eligible=#{resolution.eligible_payment_method_types} enabled=#{resolution.payment_method_types.inspect} " \
        "launch_gated_out=#{launch_gated_out} stripe_connect_account_id=#{resolution.stripe_connect_account_id.inspect}"
      )
    end
end
