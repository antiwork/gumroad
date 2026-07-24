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
#     US-locked first-launch method (Cash App Pay) joins for US buyers via the GeoIP gate below.
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
  ONE_TIME_PAYMENT_METHOD_TYPES = %w[card link klarna afterpay_clearpay affirm ideal bancontact upi cashapp us_bank_account].freeze
  # Afterpay/Clearpay, Affirm, and UPI are one-time, buyer-present only, so a recurring lifecycle
  # drops them. (Recurring carts currently fall back to Lane A before any Stripe method list is
  # built, but the eligible-policy set is logged and intersected by later units, so it must not
  # claim a recurring-incapable method.)
  RECURRING_INELIGIBLE_PAYMENT_METHOD_TYPES = %w[afterpay_clearpay affirm upi].freeze
  # Launched on the client-confirmed path: card everywhere; Link everywhere (inline — it rides
  # card's two-step confirm machinery with no return-page/webhook dependency, launched under the
  # element flags themselves since Stripe's dashboard payment-method settings are the emergency
  # kill switch, per-seller Flipper adds no useful lever); plus Cash App Pay (US-locked, region-gated
  # below; redirect — confirms via the #5664 return page). The EUR forced-currency methods
  # (iDEAL/Bancontact) launch per-method via LOCAL_METHOD_LAUNCH_FEATURES on
  # Checkout::BuyerCurrencyEligibility — see forced_currency_methods below; SEPA stays
  # unwired until its own launch. ACH Direct Debit (us_bank_account) was launched and
  # then withdrawn platform-wide: it settles in ~4 business days and content only delivers on
  # settlement, which doesn't fit digital products (gumroad-private#1143). Its webhook settlement
  # lifecycle stays wired so in-flight ACH purchases still complete. Sellers who want it anyway
  # (e.g. large-ticket sales where card limits bite) can opt back in per seller — see
  # SELLER_OPT_IN_PAYMENT_METHOD_TYPES below.
  LAUNCHED_PAYMENT_METHOD_TYPES = %w[card link cashapp].freeze
  # Methods a seller can re-enable for their own checkouts from the checkout settings page
  # (User#ach_payments_enabled?). They join the launched set only for that seller's carts and then
  # flow through every downstream gate unchanged: the US region gate (ACH debits a US bank
  # account), the PPP matrix, and the per-account capability intersection for direct-charge
  # sellers. Opting in can therefore never widen the set past what the buyer/account could
  # actually complete. Both the presenter and PreparePaymentIntentService resolve through this
  # same class with the same seller, so the Payment Element and the deferred intent stay in sync
  # (the handshake note above).
  SELLER_OPT_IN_PAYMENT_METHOD_TYPES = %w[us_bank_account].freeze
  LINK_PAYMENT_METHOD_TYPE = "link"
  # Methods that only work for US buyers on USD PaymentIntents. ACH Direct Debit debits a US bank
  # account; Cash App Pay is US-locked. These are dropped from the launched set unless GeoIP ∈ {US}.
  US_LOCKED_PAYMENT_METHOD_TYPES = %w[us_bank_account cashapp].freeze
  # UPI can only be used by Indian buyers on INR PaymentIntents. Unknown GeoIP fails safe.
  IN_LOCKED_PAYMENT_METHOD_TYPES = %w[upi].freeze
  # Never gated by the per-account capability check on direct-charge sellers. Card processing is
  # the baseline capability of any chargeable Stripe account — an account that truly can't take
  # cards is unusable no matter what we render, and an empty method list would just break the
  # Payment Element mount. Everything else — including Link, which is absent or inactive on a
  # meaningful share of connected accounts and makes Stripe reject the intent create when listed
  # (verified live, gumroad-private#1026) — waits for the account's capability snapshot.
  ALWAYS_ACCOUNT_SUPPORTED_PAYMENT_METHOD_TYPES = %w[card].freeze
  US_ALPHA2 = "US"
  IN_ALPHA2 = "IN"
  # PPP method matrix (U13). On a PPP-discounted checkout, only methods whose funding country is
  # verifiable pre-charge (card/wallets via card.country, and later sepa_debit.country) or whose
  # region lock matches the discount country (Cash App Pay / ACH are US-locked, so US-only) may be
  # offered. Methods with NO Stripe-owned funding country (Klarna/Afterpay/Affirm/PayPal/Link) are
  # gated out on PPP checkouts: their preview yields nil country, so a PPP purchase would always
  # fail closed at prepare — don't render a method that cannot complete.
  # sepa_debit is wired but dormant until SEPA launches post-FX.
  PPP_VERIFIABLE_PAYMENT_METHOD_TYPES = %w[card sepa_debit].freeze
  # Region-locked methods are allowed on a PPP checkout only when the buyer's (GeoIP) country —
  # the basis of the discount — is the lock country. The resolver's region gates already enforce
  # buyer_country == US for Cash App Pay/ACH and buyer_country == IN for UPI, so on a PPP checkout
  # they stay offered exactly when the discount country is the lock country.
  PPP_REGION_LOCKED_PAYMENT_METHOD_TYPES = (US_LOCKED_PAYMENT_METHOD_TYPES + IN_LOCKED_PAYMENT_METHOD_TYPES).freeze
  # Multi-seller and other Lane A carts keep Gumroad's existing card + PayPal set.
  LANE_A_PAYMENT_METHOD_TYPES = %w[card paypal].freeze

  Resolution = Data.define(:client_confirm_eligible, :payment_method_types, :eligible_payment_method_types, :fallback_reason, :stripe_connect_account_id) do
    def client_confirm_eligible? = client_confirm_eligible
  end

  # cart_product_currency: the ISO code (lowercase, e.g. "eur") the cart's single item is priced
  # in, or nil for multi-item carts / unknown. Only consulted by the forced-currency
  # gate below: a forced-currency method (iDEAL/Bancontact) is offered only when the cart is
  # priced in exactly the currency that method forces, because that is the only shape where the
  # Payment Element mounts in that currency (StripePaymentPresenter#method_forced_shape?) and
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

    # What Stripe actually receives, built in two conceptually separate passes:
    #
    #   1. OUR policy decisions — launch gating, the US region gate on Cash App Pay/ACH (US-GeoIP
    #      buyers only; unknown country fails safe), the forced-currency local methods (per-method
    #      launch flags in live mode, unrestricted in test mode for QA), and
    #      the PPP verifiability matrix. These express what Gumroad is willing to offer this buyer
    #      on this cart.
    #   2. A final intersection with what the charged ACCOUNT can accept. On a direct-charge
    #      (Stripe Connect) seller the PaymentIntent is created on the seller's own Stripe account,
    #      and payment method capabilities live per-account — Stripe rejects an intent create whose
    #      payment_method_types lists a method the account hasn't activated, which fails the whole
    #      checkout no matter which method the buyer picked (gumroad-private#1026). Policy never
    #      needs to know about capabilities and capabilities never need to know about policy; the
    #      intersection at the end is the whole relationship.
    #
    # Card always survives, and Link (inline, not US-locked) is unaffected by the region gate.
    def launched_method_set(eligible)
      launched = eligible & LAUNCHED_PAYMENT_METHOD_TYPES
      launched += seller_opt_in_methods(eligible)
      launched += forced_currency_methods(eligible)
      launched -= US_LOCKED_PAYMENT_METHOD_TYPES unless buyer_country == US_ALPHA2
      launched -= IN_LOCKED_PAYMENT_METHOD_TYPES unless buyer_country == IN_ALPHA2
      launched = ppp_method_matrix(launched) if ppp_discounted
      launched & account_supported_methods(launched)
    end

    # ACH Direct Debit is withdrawn from the default launched set (delayed ~4-business-day
    # settlement, gumroad-private#1143) but a seller can opt back in from the checkout settings
    # page. Added BEFORE the US region gate / PPP matrix / account-capability intersection so the
    # opt-in is subject to all of them — it re-adds the method only where it could already have
    # been offered pre-withdrawal. Only single-seller carts reach a non-Lane-A eligible set, so
    # `sellers.one?` is belt-and-braces rather than a real branch.
    def seller_opt_in_methods(eligible)
      return [] unless sellers.one? && sellers.first&.ach_payments_enabled?

      eligible & SELLER_OPT_IN_PAYMENT_METHOD_TYPES
    end

    # The methods (from our policy-resolved set) that the account the PaymentIntent will be created
    # on can actually accept.
    #
    # Platform-account (Gumroad-managed) sellers: everything — the platform account's activations
    # are under our control and every launched method is activated there.
    #
    # Direct-charge (connect) sellers: whatever the account's cached capability snapshot says, with
    # two carve-outs. Card is always kept: card processing is the baseline capability of any
    # chargeable Stripe account, and an account that truly can't take cards is unusable regardless
    # of what we render — an empty method list would just break the Payment Element mount. And when
    # no snapshot exists yet, fall back to card ONLY and enqueue a background refresh so the next
    # checkout has the real answer — checkout must never block on, or fail with, a live Stripe API
    # call. Link is deliberately NOT assumed on a miss: link_payments is absent/inactive on a
    # meaningful share of connected accounts (a live 40-account sample found it absent on half),
    # and listing it on such an account makes Stripe reject the intent create — failing the whole
    # checkout, the exact gumroad-private#1026 failure mode. One card-only checkout per uncached
    # seller beats gambling their (often first) sale on it.
    def account_supported_methods(launched)
      return launched unless direct_charge_seller?

      connect_account = sellers.first.stripe_connect_account
      gated = launched - ALWAYS_ACCOUNT_SUPPORTED_PAYMENT_METHOD_TYPES
      availability = StripeConnectPaymentMethodAvailabilityService.new(connect_account)
      available = availability.available_payment_method_types(gated)
      if available.nil?
        # Prefetch even when nothing is gated on THIS checkout (e.g. a PPP card-only cart):
        # the snapshot is per-seller, and the next buyer may need it.
        enqueue_availability_refresh(connect_account)
        return ALWAYS_ACCOUNT_SUPPORTED_PAYMENT_METHOD_TYPES
      end

      # Self-heal for dropped webhooks: a stale snapshot is still used (checkout never blocks),
      # but triggers a background re-fetch so a capability change whose webhook was lost — e.g.
      # discarded by the refresh worker's until_executed lock mid-refresh — is bounded by
      # SNAPSHOT_MAX_AGE instead of persisting forever.
      enqueue_availability_refresh(connect_account) if availability.snapshot_stale?

      ALWAYS_ACCOUNT_SUPPORTED_PAYMENT_METHOD_TYPES + available
    end

    # Best-effort: the refresh improves FUTURE checkouts and must never break THIS one. A raise
    # here (e.g. Redis unavailable at enqueue) would otherwise fail a checkout render that could
    # have completed fine with the methods already resolved.
    def enqueue_availability_refresh(connect_account)
      RefreshMerchantAccountPaymentMethodAvailabilityWorker.perform_async(connect_account.id)
    rescue => e
      Rails.logger.error("Failed to enqueue payment method availability refresh for merchant account #{connect_account.id}: #{e.class} => #{e.message}")
    end

    # The EUR forced-currency methods (iDEAL/Bancontact) surface in two situations:
    #
    #   QA (Stripe test mode): the seller has the internal buyer-currency flags on and the
    #   cart's single item is priced in the currency the method forces. This is the
    #   pre-launch manual QA surface on preview apps/staging.
    #
    #   Production (live mode): additionally, the method's own per-method launch flag
    #   (Checkout::BuyerCurrencyEligibility::LOCAL_METHOD_LAUNCH_FEATURES) must be active
    #   for the seller — the #5362 Phase 4 ramp lever, one flag per method so iDEAL can
    #   ramp and roll back independently of the rest of the cohort.
    #
    # In both modes the cart-shape condition mirrors the presenter's method_forced_shape?
    # gate: only a single item priced in the forced currency mounts the Payment Element in
    # that currency, and a forced-currency method listed on a USD element/intent makes
    # Stripe reject the whole element session (no payment form renders at all — this broke
    # flag-on sellers' plain USD checkouts before the gate was added).
    def forced_currency_methods(eligible)
      return [] unless sellers.one? && Checkout::BuyerCurrencyEligibility.seller_enabled?(sellers.first)

      methods_for_cart_currency = (eligible & Checkout::BuyerCurrencyEligibility::FORCED_CURRENCY_PAYMENT_METHODS.keys).select do |method|
        Checkout::BuyerCurrencyEligibility.forced_currency_for(method) == cart_product_currency
      end
      return [] if methods_for_cart_currency.empty?

      # The prepare-time eligibility check rejects a forced-currency intent when the
      # account doesn't HOLD USD (stored-currency check). Mirror only that half here.
      # Deliberately NOT the marker-aware usd_settling_merchant_account?: the methods
      # this resolver offers are always the direct-listed-amount shape (single item
      # priced in the forced currency — the select above), which charges the listed
      # price with no FX quote, so the learned mismatch marker is irrelevant to them.
      # Gating on the marker here is what made iDEAL disappear platform-wide on
      # 2026-07-23: enabling the iDEAL/SEPA capabilities made the platform account
      # settle EUR in EUR, the EUR marker was recorded, and the tab never rendered for
      # any Gumroad-managed seller (gumroad-private#933).
      return [] unless forced_currency_settlement_supported?

      methods_for_cart_currency.select do |method|
        Checkout::BuyerCurrencyEligibility.stripe_test_mode? ||
          Checkout::BuyerCurrencyEligibility.local_method_launched?(method, sellers.first)
      end
    end

    def forced_currency_settlement_supported?
      seller = sellers.first
      merchant_account = seller.merchant_account(StripeChargeProcessor.charge_processor_id) ||
                         MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id)
      return false if merchant_account.blank?

      Checkout::BuyerCurrencyEligibility.usd_holding_merchant_account?(merchant_account)
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
