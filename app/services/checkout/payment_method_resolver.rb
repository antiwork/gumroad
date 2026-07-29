# frozen_string_literal: true

# Server-authoritative policy boundary for the client-confirmed Intent path (Lane B): whether a cart
# may confirm client-side at all, and which Stripe payment methods it may use. The frontend cannot
# widen it — payment_method_types is the intersection of the eligible set with a hardcoded launched
# set.
#
#   - client_confirm_eligible?: may this cart take Lane B, or must it fall back to Lane A.
#   - eligible_payment_method_types: the policy set the cart *could* use. Logged, and intersected
#     downstream with per-method launch/PPP gates.
#   - payment_method_types: what Stripe actually receives today.
#
# The deferred PaymentIntent's payment_method_types must equal the Payment Element's or Stripe
# rejects the ConfirmationToken — hence an explicit array, never automatic_payment_methods. The
# presenter and PreparePaymentIntentService both resolve through here from the same GeoIP basis, and
# the service hard-stops an ineligible cart before creating the intent, so a mismatch fails closed.
class Checkout::PaymentMethodResolver
  # Buyer-present single-seller dynamic set. Apple Pay / Google Pay ride on "card" in the Payment
  # Element, so they are not separate types here. us_bank_account (ACH Direct Debit) is a
  # delayed-notification method: it settles asynchronously via the PaymentIntent webhook lifecycle.
  ONE_TIME_PAYMENT_METHOD_TYPES = %w[card link klarna afterpay_clearpay affirm ideal bancontact upi pix cashapp us_bank_account alipay].freeze
  # Dropped on a recurring lifecycle, for four different reasons:
  #   - afterpay_clearpay, affirm, upi: one-time, buyer-present only.
  #   - ideal, bancontact, pix: one-shot bank approvals with no stored mandate — renewals would
  #     have nothing to charge against (re-billing needs a SEPA mandate we don't collect).
  #   - alipay: Stripe gates recurring Alipay behind approval and excludes it from subscription
  #     mode, so it stays out until that changes, not until we widen our launch scope.
  #   - klarna: a launch decision, not a capability limit — memberships and preorders are out of
  #     scope for its first launch (gumroad-private#933).
  # Recurring carts fall back to Lane A before a Stripe list is built, but this set is logged and
  # intersected downstream, so it must not claim a recurring-incapable method.
  RECURRING_INELIGIBLE_PAYMENT_METHOD_TYPES = %w[afterpay_clearpay affirm upi pix klarna alipay ideal bancontact].freeze
  # Always-on for the client-confirmed path. Link is inline (rides card's confirm machinery, no
  # return page); cashapp is US-locked and region-gated below.
  # Not here because they are flag-gated instead: iDEAL/Bancontact (LOCAL_METHOD_LAUNCH_FEATURES on
  # Checkout::BuyerCurrencyEligibility), Klarna and Alipay (KLARNA_/ALIPAY_LAUNCH_FEATURE). SEPA is
  # unwired until its own launch.
  # ACH (us_bank_account) was launched then withdrawn platform-wide — ~4 business days to settle and
  # content only delivers on settlement (gumroad-private#1143). Its webhook lifecycle stays wired so
  # in-flight purchases complete, and sellers can opt back in via SELLER_OPT_IN_PAYMENT_METHOD_TYPES.
  LAUNCHED_PAYMENT_METHOD_TYPES = %w[card link cashapp].freeze
  # Re-enabled per seller from checkout settings (User#ach_payments_enabled?). Joins the launched
  # set for that seller's carts only, and still passes every downstream gate (US region, PPP matrix,
  # per-account capabilities), so opting in cannot widen the set past what the buyer could complete.
  SELLER_OPT_IN_PAYMENT_METHOD_TYPES = %w[us_bank_account].freeze
  LINK_PAYMENT_METHOD_TYPE = "link"
  # Per-seller Flipper flag so it can ramp and roll back independently (gumroad-private#933).
  # Unlike iDEAL/UPI, Klarna forces no presentment currency, so it rides the canonical-USD lane and
  # is absent from Checkout::BuyerCurrencyEligibility's forced-currency registry.
  KLARNA_PAYMENT_METHOD_TYPE = "klarna"
  KLARNA_LAUNCH_FEATURE = :checkout_local_method_klarna
  # US only: Stripe requires the buyer's location currency as the presentment currency for Klarna,
  # and this lane only creates USD intents — a UK/DE/SE buyer's confirm would be rejected. Reaching
  # them needs the buyer-currency lane. Deliberately NOT in US_LOCKED_PAYMENT_METHOD_TYPES, which
  # feeds the PPP allowance: Klarna stays out of PPP checkouts (funding country unverifiable
  # pre-charge — see ppp_method_matrix).
  KLARNA_SUPPORTED_BUYER_COUNTRY = "US"
  # Outside every Klarna option's range the confirm fails with no recoverable buyer action, so fail
  # eligibility closed instead: offer it only inside the widest USD window (Pay in full, 0–4,000),
  # floored at $1 so near-zero carts never render it. Unknown total also fails closed.
  KLARNA_MIN_USD_CHARGE_CENTS = 1_00
  KLARNA_MAX_USD_CHARGE_CENTS = 4_000_00
  # Alipay (Chinese digital wallet; redirect-based) launches behind its own per-seller Flipper
  # flag, the same ramp lever pattern as Klarna and the forced-currency local methods, so it can
  # ramp and roll back independently (gumroad-private#1339). Like Klarna and unlike
  # iDEAL/Bancontact/UPI it does NOT force a presentment currency — USD is a supported Alipay
  # presentment currency for a US business — so it stays out of
  # Checkout::BuyerCurrencyEligibility's forced-currency registry and rides the existing
  # canonical-USD element/intent lane.
  ALIPAY_PAYMENT_METHOD_TYPE = "alipay"
  ALIPAY_LAUNCH_FEATURE = :checkout_local_method_alipay
  # Methods that only work for US buyers on USD PaymentIntents. ACH Direct Debit debits a US bank
  # account; Cash App Pay is US-locked. These are dropped from the launched set unless GeoIP ∈ {US}.
  US_LOCKED_PAYMENT_METHOD_TYPES = %w[us_bank_account cashapp].freeze
  # UPI can only be used by Indian buyers on INR PaymentIntents. Unknown GeoIP fails safe.
  IN_LOCKED_PAYMENT_METHOD_TYPES = %w[upi].freeze
  # Pix can only be used by Brazilian buyers on BRL PaymentIntents: it settles over Brazil's
  # domestic instant-payment rails, so the buyer needs an account at a Brazilian bank. Unknown
  # GeoIP fails safe.
  BR_LOCKED_PAYMENT_METHOD_TYPES = %w[pix].freeze
  PIX_PAYMENT_METHOD_TYPE = "pix"
  # Stripe's Pix transaction window: at least 0.50 BRL, at most 3,000 USD per payment
  # (https://docs.stripe.com/payments/pix#transaction-limits). The floor is in the presentment
  # currency (BRL, the only currency Pix charges in) and the ceiling is quoted in USD, which is
  # also the currency Gumroad's canonical cart total is already in — so each bound is checked
  # against the figure that is natively in its own currency, with no FX conversion invented here.
  # Enforced at intent-prepare time against the FINAL charged amounts rather than in this resolver:
  # a BRL cart has no USD item total for the resolver to read (the presenter only passes one for
  # USD-priced carts), and Stripe validates the intent's final amount anyway. See
  # Order::PreparePaymentIntentService#block_pix_amount_outside_window.
  # Stripe also caps a single buyer at 10,000 USD of Pix payments per month with one business.
  # That is a property of the buyer's history, not of this cart, so no cart-shaped gate can see
  # it: such a payment fails at confirm and surfaces through the payment_intent.payment_failed
  # webhook like any other decline.
  PIX_MIN_BRL_CHARGE_CENTS = 50
  PIX_MAX_USD_CHARGE_CENTS = 3_000_00

  # Never gated by the per-account capability check on direct-charge sellers. Card processing is
  # the baseline capability of any chargeable Stripe account — an account that truly can't take
  # cards is unusable no matter what we render, and an empty method list would just break the
  # Payment Element mount. Everything else — including Link, which is absent or inactive on a
  # meaningful share of connected accounts and makes Stripe reject the intent create when listed
  # (verified live, gumroad-private#1026) — waits for the account's capability snapshot.
  ALWAYS_ACCOUNT_SUPPORTED_PAYMENT_METHOD_TYPES = %w[card].freeze
  US_ALPHA2 = "US"
  IN_ALPHA2 = "IN"
  BR_ALPHA2 = "BR"
  # PPP method matrix (U13). On a PPP-discounted checkout, only methods whose funding country is
  # verifiable pre-charge (card/wallets via card.country, and later sepa_debit.country) or whose
  # region lock matches the discount country (Cash App Pay / ACH are US-locked, so US-only) may be
  # offered. Methods with NO Stripe-owned funding country (Klarna/Afterpay/Affirm/PayPal/Link, and
  # Alipay — a wallet whose payment method exposes no funding country either) are gated out on PPP
  # checkouts: their preview yields nil country, so a PPP purchase would always fail closed at
  # prepare — don't render a method that cannot complete.
  # sepa_debit is wired but dormant until SEPA launches post-FX.
  PPP_VERIFIABLE_PAYMENT_METHOD_TYPES = %w[card sepa_debit].freeze
  # Region-locked methods are allowed on a PPP checkout only when the buyer's (GeoIP) country —
  # the basis of the discount — is the lock country. The resolver's region gates already enforce
  # buyer_country == US for Cash App Pay/ACH, buyer_country == IN for UPI, and buyer_country == BR
  # for Pix, so on a PPP checkout they stay offered exactly when the discount country is the lock
  # country.
  PPP_REGION_LOCKED_PAYMENT_METHOD_TYPES = (US_LOCKED_PAYMENT_METHOD_TYPES + IN_LOCKED_PAYMENT_METHOD_TYPES + BR_LOCKED_PAYMENT_METHOD_TYPES).freeze
  # Multi-seller and other Lane A carts keep Gumroad's existing card + PayPal set.
  LANE_A_PAYMENT_METHOD_TYPES = %w[card paypal].freeze

  Resolution = Data.define(:client_confirm_eligible, :payment_method_types, :eligible_payment_method_types, :fallback_reason, :stripe_connect_account_id) do
    def client_confirm_eligible? = client_confirm_eligible
  end

  # Whether Klarna can be listed on an intent created for this seller's account. Platform-account
  # (Gumroad-managed) sellers always pass — the platform account is US-based. Direct-charge
  # sellers pass only when their connected account's country is US: Stripe's Klarna cross-border
  # rule applies to the account the intent is created on, and an incompatible
  # payment_method_types entry fails the ENTIRE intent create, taking card down with it
  # (gumroad-private#1026). An unknown country fails closed. Exposed at class level because the
  # previewed-method append in Order::PreparePaymentIntentService must re-check the SAME
  # account gate before re-adding a klarna token — capability/account drift between the Element
  # mounting and prepare running must not re-append a method the resolver correctly dropped.
  def self.klarna_supported_merchant_account?(seller)
    us_based_merchant_account?(seller)
  end

  # Whether Alipay can be listed on an intent created for this seller's account. Same shape of
  # rule as Klarna's, for a different reason: Stripe ties each Alipay presentment currency to the
  # business's country (docs.stripe.com/payments/alipay — "Supported currencies": `usd` maps to
  # United States only; only `cny` is valid for any country). This lane creates USD intents, so a
  # non-US connected account cannot carry an alipay entry even when its alipay_payments capability
  # is genuinely active — and Standard (dashboard) connected accounts can enable Alipay themselves
  # from any of Stripe's ~40 supported business countries, so "active capability on a non-US
  # account" is an ordinary state, not an exotic one. The capability snapshot cannot catch it: the
  # capability really is active; what is invalid is the (method, account country, intent currency)
  # combination, and an incompatible payment_method_types entry fails the ENTIRE intent create,
  # taking card down with it (gumroad-private#1026). An unknown country fails closed. Exposed at
  # class level for the same reason as Klarna's: the previewed-method append in
  # Order::PreparePaymentIntentService must re-check the SAME account gate.
  def self.alipay_supported_merchant_account?(seller)
    us_based_merchant_account?(seller)
  end

  # Platform-account (Gumroad-managed) sellers always pass — the platform account is US-based.
  # Direct-charge sellers pass only when their connected account's country is US. Unknown fails
  # closed.
  def self.us_based_merchant_account?(seller)
    return true unless seller&.has_stripe_account_connected?

    seller.stripe_connect_account&.country == US_ALPHA2
  end

  # cart_product_currency: the ISO code (lowercase, e.g. "eur") every cart item is priced in,
  # or nil for mixed-currency / unknown carts. Only consulted by the forced-currency gate below:
  # a forced-currency method (iDEAL/Bancontact/UPI) is offered only when the whole cart is priced
  # in exactly the currency that method forces, because that is the only shape where the Payment
  # Element mounts in that currency (StripePaymentPresenter#method_forced_shape?) and the deferred
  # intent can be created in it. Offering the methods on any other cart puts forced-currency
  # entries on a USD element/intent, which Stripe rejects outright (no element mounts at all).
  #
  # cart_total_usd_cents: the cart's total in USD cents, or nil when unknown. Only consulted by
  # the Klarna gate (Stripe enforces per-country transaction limits for Klarna, so carts outside
  # the window must not render it — see KLARNA_MIN/MAX_USD_CHARGE_CENTS). BOTH callers (the
  # presenter and Order::PreparePaymentIntentService) pass the same pre-tax, pre-discount item
  # total, so the Element's method list and the deferred intent's resolve identically. Stripe,
  # however, enforces the limit against the intent's FINAL amount (tax and discounts included),
  # which can drift out of the window after the Element mounts — that case is handled by
  # prepare's own final-amount gate (see Order::PreparePaymentIntentService
  # #block_klarna_final_amount_outside_window), not by this resolver input. Nil fails closed
  # for Klarna only.
  def initialize(sellers:, recurring: false, commission: false, setup_for_future: false, buyer_country: nil, ppp_discounted: false, cart_product_currency: nil, cart_total_usd_cents: nil)
    @sellers = sellers
    @recurring = recurring
    @commission = commission
    @setup_for_future = setup_for_future
    @buyer_country = buyer_country
    @ppp_discounted = ppp_discounted
    @cart_product_currency = cart_product_currency
    @cart_total_usd_cents = cart_total_usd_cents
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
    attr_reader :sellers, :recurring, :commission, :setup_for_future, :buyer_country, :ppp_discounted, :cart_product_currency, :cart_total_usd_cents

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
      forced = forced_currency_methods(eligible)
      launched += forced
      # Klarna never joins a forced-currency element mount: when a forced-currency method (iDEAL/
      # UPI) survives, the Payment Element mounts in EUR/INR and the deferred intent is created in
      # that currency — but the Klarna gate below reasons in USD (the amount window, and the US
      # cross-border rule that ties Klarna on this lane to USD intents). Mixed listings would put
      # a USD-only-vetted method on a non-USD intent, so the two surfaces stay mutually exclusive.
      launched += klarna_methods(eligible) if forced.empty?
      # Alipay is withheld from a forced-currency element mount for the same reason as Klarna:
      # when a forced-currency method survives, the Element mounts in EUR/INR and the deferred
      # intent is created in that currency, but this gate vets Alipay for the canonical-USD lane
      # only. Listing a USD-vetted method on a non-USD intent is what makes Stripe reject the
      # whole intent create, taking card down with it (gumroad-private#1026).
      launched += alipay_methods(eligible) if forced.empty?
      launched -= US_LOCKED_PAYMENT_METHOD_TYPES unless buyer_country == US_ALPHA2
      launched -= IN_LOCKED_PAYMENT_METHOD_TYPES unless buyer_country == IN_ALPHA2
      launched -= BR_LOCKED_PAYMENT_METHOD_TYPES unless buyer_country == BR_ALPHA2
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

    # Klarna's launch gate: offered only when the seller's own launch flag
    # (checkout_local_method_klarna, the gumroad-private#933 ramp lever) is active. Unlike the
    # forced-currency methods there is no blanket Stripe-test-mode bypass — the flag is the QA
    # switch too (activate it for a QA seller on preview/staging), because a test-mode bypass
    # would silently offer Klarna on every test-keyed checkout regardless of the ramp decision.
    # On top of the flag, four Klarna-specific cart gates — all fail closed:
    #   - US buyers only in v1 (see KLARNA_SUPPORTED_BUYER_COUNTRY; unknown GeoIP fails safe),
    #   - the cart total must sit inside Stripe's Klarna USD transaction window (a cart outside
    #     it renders a method whose confirm Stripe rejects with no buyer recourse),
    #   - one-time carts only (recurring is already stripped from `eligible` by
    #     RECURRING_INELIGIBLE_PAYMENT_METHOD_TYPES, which the intersection here inherits),
    #   - for direct-charge (connect) sellers, the connected account itself must be US-based:
    #     Stripe's Klarna cross-border rule applies to the account the intent is created on, so
    #     a non-US connected account with an active klarna_payments capability would still have
    #     its USD/US-buyer intent create rejected — and an incompatible payment_method_types
    #     entry fails the ENTIRE intent create, taking card down with it (the
    #     gumroad-private#1026 failure mode). The capability snapshot check downstream
    #     (account_supported_methods) can't catch this because the capability really is active.
    def klarna_methods(eligible)
      return [] unless sellers.one?
      return [] unless eligible.include?(KLARNA_PAYMENT_METHOD_TYPE)
      return [] unless buyer_country == KLARNA_SUPPORTED_BUYER_COUNTRY
      return [] unless klarna_amount_within_limits?
      return [] unless klarna_supported_merchant_account?
      return [] unless Feature.active?(KLARNA_LAUNCH_FEATURE, sellers.first)

      [KLARNA_PAYMENT_METHOD_TYPE]
    end

    def klarna_amount_within_limits?
      cart_total_usd_cents.present? &&
        cart_total_usd_cents >= KLARNA_MIN_USD_CHARGE_CENTS &&
        cart_total_usd_cents <= KLARNA_MAX_USD_CHARGE_CENTS
    end

    # Alipay's launch gate: offered only when the seller's own launch flag
    # (checkout_local_method_alipay, the gumroad-private#1339 ramp lever) is active. As with
    # Klarna there is deliberately no Stripe-test-mode bypass — the flag is the QA switch too
    # (activate it for a QA seller on preview/staging), because a test-mode bypass would offer
    # Alipay on every test-keyed checkout regardless of the ramp decision.
    #
    # Alipay needs fewer cart gates than Klarna, and the absences are deliberate:
    #   - No buyer-country gate. Alipay is not region-locked the way Cash App Pay is: Stripe
    #     accepts an Alipay payment from any buyer with an Alipay account, and the buyers this
    #     targets are largely NOT in mainland China (the sizing on gumroad-private#1339 found
    #     mainland buyer IPs account for 12 sales in 30 days, while Chinese cards are used from
    #     Hong Kong, Taiwan and Singapore). A GeoIP lock would gate out most of the cohort.
    #   - No amount window. Stripe publishes no per-country Alipay transaction limits of the
    #     kind that forced Klarna's fail-closed window.
    #   - One-time carts only, inherited from RECURRING_INELIGIBLE_PAYMENT_METHOD_TYPES having
    #     already stripped alipay from `eligible` on a recurring lifecycle.
    #
    # For direct-charge (connect) sellers the connected account must be US-based, exactly as for
    # Klarna, though the underlying rule differs: Stripe ties each Alipay presentment currency to
    # the business's country and `usd` maps to the United States only (only `cny` is valid for any
    # country). This lane creates USD intents on the connected account, so an alipay entry on a
    # non-US account's intent is rejected outright — and because an incompatible
    # payment_method_types entry fails the ENTIRE intent create, that would take card down with it
    # (the gumroad-private#1026 failure mode). The per-account capability intersection downstream
    # (account_supported_methods) cannot substitute for this gate: Standard (dashboard) connected
    # accounts can enable Alipay themselves from any of Stripe's ~40 supported business countries,
    # so an active alipay_payments capability on a non-US account is an ordinary state — the
    # capability really is active; it is the (method, account country, intent currency) combination
    # that is invalid.
    def alipay_methods(eligible)
      return [] unless sellers.one?
      return [] unless eligible.include?(ALIPAY_PAYMENT_METHOD_TYPE)
      return [] unless alipay_supported_merchant_account?
      return [] unless Feature.active?(ALIPAY_LAUNCH_FEATURE, sellers.first)

      [ALIPAY_PAYMENT_METHOD_TYPE]
    end

    # Platform-account sellers always pass (the platform account is US-based). Direct-charge
    # sellers pass only when their connected account's country is US — see klarna_methods'
    # fourth gate. An unknown country fails closed.
    def klarna_supported_merchant_account?
      self.class.klarna_supported_merchant_account?(sellers.first)
    end

    # Same US-account rule as Klarna's, for the USD-presentment reason documented on
    # .alipay_supported_merchant_account?. An unknown country fails closed.
    def alipay_supported_merchant_account?
      self.class.alipay_supported_merchant_account?(sellers.first)
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

    # The forced-currency methods (iDEAL/Bancontact/UPI) surface in two situations:
    #
    #   QA (Stripe test mode): the seller has the internal buyer-currency flags on and the
    #   whole cart is priced in the currency the method forces. This is the
    #   pre-launch manual QA surface on preview apps/staging.
    #
    #   Production (live mode): additionally, the method's own per-method launch flag
    #   (Checkout::BuyerCurrencyEligibility::LOCAL_METHOD_LAUNCH_FEATURES) must be active
    #   for the seller — the #5362 Phase 4 ramp lever, one flag per method so iDEAL can
    #   ramp and roll back independently of the rest of the cohort.
    #
    # In both modes the cart-shape condition mirrors the presenter's method_forced_shape?
    # gate: only a cart priced uniformly in the forced currency mounts the Payment Element in
    # that currency, and a forced-currency method listed on a USD element/intent makes
    # Stripe reject the whole element session (no payment form renders at all — this broke
    # flag-on sellers' plain USD checkouts before the gate was added).
    def forced_currency_methods(eligible)
      return [] unless sellers.one? && Checkout::BuyerCurrencyEligibility.seller_enabled?(sellers.first)

      methods_for_cart_currency = (eligible & Checkout::BuyerCurrencyEligibility::FORCED_CURRENCY_PAYMENT_METHODS.keys).select do |method|
        Checkout::BuyerCurrencyEligibility.forced_currency_for(method) == cart_product_currency
      end
      return [] if methods_for_cart_currency.empty?

      # No settlement gate here. The methods this resolver offers are always the
      # direct-listed-amount shape (the whole cart priced in the forced currency — the
      # select above), which charges the listed price with no FX quote anywhere, so no
      # property of the charging account's balance currency can make the charge fail.
      # Stripe is happy to create a EUR intent on a EUR-settling account; the per-account
      # capability intersection further down (account_supported_methods) is what actually
      # establishes the account can take the method.
      #
      # Two narrower versions of this gate were removed in turn, both because they hid
      # methods from checkouts that could complete: the marker-aware
      # usd_settling_merchant_account? made iDEAL disappear platform-wide on 2026-07-23
      # (enabling the iDEAL/SEPA capabilities made the platform account settle EUR in EUR,
      # so the EUR marker was recorded — gumroad-private#933), and the stored-currency
      # usd_holding_settlement_account? that replaced it still withheld the methods from
      # every Stripe Connect seller settling in euros, which is most eurozone sellers and
      # the majority of the lane's addressable volume (gumroad-private#1442).

      methods_for_cart_currency.select do |method|
        Checkout::BuyerCurrencyEligibility.stripe_test_mode? ||
          Checkout::BuyerCurrencyEligibility.local_method_launched?(method, sellers.first)
      end
    end

    # U13: a PPP-discounted checkout only offers methods the pre-charge country check can verify
    # (card/wallets, later sepa_debit) or whose region lock matches the buyer's country (Cash App
    # Pay / ACH — already region-gated above, so surviving entries match by construction). Methods
    # with no Stripe-owned funding country (Link, Klarna and Alipay today; Afterpay/Affirm/PayPal
    # when they launch) are dropped: `previewed_country` returns nil and the purchase would fail closed
    # at prepare anyway — never render a method that cannot complete the discounted purchase.
    # Klarna's US buyer gate is a policy country check on GeoIP, not a Stripe-owned funding
    # country, so it does not qualify for the region-locked allowance.
    # Alipay is dropped by simple omission from both allowlists: it is neither funding-country
    # verifiable nor region-locked, so no explicit subtraction is needed here.
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
