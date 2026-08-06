# frozen_string_literal: true

# Server-authoritative policy boundary for the client-confirmed Intent path (Lane B): whether a cart
# may confirm client-side at all, and which Stripe payment methods it may use. The frontend cannot
# widen it.
#
# The Payment Element uses this list as its baseline menu. Prepare may narrow the deferred intent,
# but it must retain the selected method. Both sides resolve here from the same GeoIP basis, and the
# service hard-stops an ineligible cart before creating the intent, so policy drift fails closed.
#
# Listing a method the account or the intent's currency cannot take fails the ENTIRE intent create,
# taking card down with it (gumroad-private#1026) — that is why every gate below fails closed.
class Checkout::PaymentMethodResolver
  # Buyer-present single-seller dynamic set. Apple Pay / Google Pay ride on "card" in the Payment
  # Element, so they are not separate types here.
  ONE_TIME_PAYMENT_METHOD_TYPES = %w[card link klarna afterpay_clearpay affirm ideal bancontact upi pix cashapp us_bank_account alipay].freeze
  # Dropped on the general recurring lifecycle:
  #   - afterpay_clearpay, affirm, upi: buyer-present only. The narrowly scoped UPI Autopay
  #     registration path below replaces this set with card + UPI.
  #   - ideal, bancontact, pix: one-shot bank approvals with no stored mandate. Re-billing
  #     iDEAL/Bancontact needs a SEPA Direct Debit mandate we don't collect; Pix cannot re-bill.
  #   - alipay: Stripe gates recurring Alipay behind approval and excludes it from subscription mode.
  #   - klarna: a launch decision, not a capability limit (gumroad-private#933).
  RECURRING_INELIGIBLE_PAYMENT_METHOD_TYPES = %w[afterpay_clearpay affirm upi pix klarna alipay ideal bancontact].freeze
  # Always-on for the client-confirmed path; cashapp is still region-gated below. Everything else is
  # flag-gated instead: the forced-currency methods (LOCAL_METHOD_LAUNCH_FEATURES on
  # Checkout::BuyerCurrencyEligibility), Klarna and Alipay (KLARNA_/ALIPAY_LAUNCH_FEATURE). SEPA is
  # unwired until its own launch. ACH (us_bank_account) was launched then withdrawn platform-wide —
  # ~4 business days to settle and content only delivers on settlement (gumroad-private#1143). Its
  # webhook lifecycle stays wired so in-flight purchases complete; sellers opt back in via
  # SELLER_OPT_IN_PAYMENT_METHOD_TYPES.
  LAUNCHED_PAYMENT_METHOD_TYPES = %w[card link cashapp].freeze
  # Re-enabled per seller from checkout settings (User#ach_payments_enabled?), still subject to every
  # downstream gate, so opting in cannot widen the set past what the buyer could complete.
  SELLER_OPT_IN_PAYMENT_METHOD_TYPES = %w[us_bank_account].freeze
  LINK_PAYMENT_METHOD_TYPE = "link"
  UPI_PAYMENT_METHOD_TYPE = "upi"
  UPI_RECURRING_LAUNCH_FEATURE = :checkout_local_method_upi_recurring
  # Global emergency stop for acquisition and every existing UPI renewal.
  UPI_RECURRING_SERVICING_FEATURE = :upi_autopay_renewals
  # Stripe caps each UPI recurring debit at INR 15,000. Gumroad stores INR in paise.
  UPI_RECURRING_MAX_INR_CENTS = 1_500_000
  # Per-seller Flipper flag so it can ramp and roll back independently (gumroad-private#933).
  # Klarna forces no presentment currency, so it rides the canonical-USD lane and is absent from
  # Checkout::BuyerCurrencyEligibility's forced-currency registry.
  KLARNA_PAYMENT_METHOD_TYPE = "klarna"
  KLARNA_LAUNCH_FEATURE = :checkout_local_method_klarna
  # US only: Stripe requires the buyer's location currency as Klarna's presentment currency and this
  # lane only creates USD intents, so a UK/DE/SE buyer's confirm would be rejected — reaching them
  # needs the buyer-currency lane. Deliberately NOT in US_LOCKED_PAYMENT_METHOD_TYPES, which feeds
  # the PPP allowance; Klarna stays out of PPP checkouts (see ppp_method_matrix).
  KLARNA_SUPPORTED_BUYER_COUNTRY = "US"
  # The widest USD Klarna window (Pay in full, 0–4,000), floored at $1 so near-zero carts never
  # render it. Outside every option's range the confirm fails with no recoverable buyer action.
  KLARNA_MIN_USD_CHARGE_CENTS = 1_00
  KLARNA_MAX_USD_CHARGE_CENTS = 4_000_00
  # Per-seller Flipper flag so it can ramp and roll back independently (gumroad-private#1339).
  # Like Klarna, Alipay forces no presentment currency — USD is a supported Alipay presentment
  # currency for a US business — so it rides the canonical-USD lane and is absent from
  # Checkout::BuyerCurrencyEligibility's forced-currency registry.
  ALIPAY_PAYMENT_METHOD_TYPE = "alipay"
  ALIPAY_LAUNCH_FEATURE = :checkout_local_method_alipay
  # Only work for US buyers on USD PaymentIntents (ACH debits a US bank account, Cash App Pay is
  # US-locked). Dropped unless GeoIP is US.
  US_LOCKED_PAYMENT_METHOD_TYPES = %w[us_bank_account cashapp].freeze
  # Indian buyers on INR PaymentIntents only. Unknown GeoIP fails safe.
  IN_LOCKED_PAYMENT_METHOD_TYPES = %w[upi].freeze
  # Brazilian buyers on BRL PaymentIntents only — Pix settles over Brazil's domestic instant-payment
  # rails, so the buyer needs an account at a Brazilian bank. Unknown GeoIP fails safe.
  BR_LOCKED_PAYMENT_METHOD_TYPES = %w[pix].freeze
  PIX_PAYMENT_METHOD_TYPE = "pix"
  # Stripe's Pix transaction window: at least 0.50 BRL, at most 3,000 USD per payment
  # (https://docs.stripe.com/payments/pix#transaction-limits). Each bound stays in the currency
  # Stripe quotes it in — no FX conversion invented here. Enforced against the FINAL charged amounts
  # in Order::PreparePaymentIntentService#block_pix_amount_outside_window, not in this resolver: a
  # BRL cart has no USD item total for the resolver to read.
  # Stripe also caps one buyer at 10,000 USD of Pix per month with one business. That is buyer
  # history, not cart shape, so no gate here can see it — such a payment fails at confirm and
  # surfaces through payment_intent.payment_failed like any other decline.
  PIX_MIN_BRL_CHARGE_CENTS = 50
  PIX_MAX_USD_CHARGE_CENTS = 3_000_00

  # Never gated by the per-account capability check: card is the baseline capability of any
  # chargeable Stripe account, and an empty method list would just break the Payment Element mount.
  # Everything else waits for the account's capability snapshot — including Link, which is
  # absent/inactive on a meaningful share of connected accounts.
  ALWAYS_ACCOUNT_SUPPORTED_PAYMENT_METHOD_TYPES = %w[card].freeze
  US_ALPHA2 = "US"
  IN_ALPHA2 = "IN"
  BR_ALPHA2 = "BR"
  # PPP method matrix (U13): a PPP-discounted checkout may only offer methods whose funding country
  # Stripe exposes pre-charge (card.country, later sepa_debit.country). sepa_debit is wired but
  # dormant until SEPA launches post-FX.
  PPP_VERIFIABLE_PAYMENT_METHOD_TYPES = %w[card sepa_debit].freeze
  # Also allowed on a PPP checkout: region-locked methods, because the discount is based on the
  # buyer's GeoIP country and the region gates above already require it to be the lock country.
  PPP_REGION_LOCKED_PAYMENT_METHOD_TYPES = (US_LOCKED_PAYMENT_METHOD_TYPES + IN_LOCKED_PAYMENT_METHOD_TYPES + BR_LOCKED_PAYMENT_METHOD_TYPES).freeze
  # Multi-seller and other Lane A carts keep Gumroad's existing card + PayPal set.
  LANE_A_PAYMENT_METHOD_TYPES = %w[card paypal].freeze

  Resolution = Data.define(:client_confirm_eligible, :payment_method_types, :eligible_payment_method_types, :fallback_reason, :stripe_connect_account_id) do
    def client_confirm_eligible? = client_confirm_eligible
  end

  # Stripe's Klarna cross-border rule applies to the account the intent is created on, so a
  # direct-charge seller's connected account must itself be US. Exposed at class level because the
  # previewed-method append in Order::PreparePaymentIntentService must re-check the SAME gate before
  # re-adding a klarna token — account drift between the Element mounting and prepare running must
  # not re-append a method the resolver correctly dropped.
  def self.klarna_supported_merchant_account?(seller)
    us_based_merchant_account?(seller)
  end

  # Same US-account rule as Klarna's, for a different reason: Stripe ties each Alipay presentment
  # currency to the business's country (docs.stripe.com/payments/alipay — `usd` maps to the United
  # States only; only `cny` is valid for any country), and this lane creates USD intents.
  # account_supported_methods cannot substitute for this gate: a Standard (dashboard) connected
  # account in any of Stripe's ~40 Alipay business countries can enable the capability itself, so an
  # active alipay_payments capability on a non-US account is ordinary — what is invalid is the
  # (method, account country, intent currency) combination. Exposed at class level for the same
  # reason as Klarna's.
  def self.alipay_supported_merchant_account?(seller)
    us_based_merchant_account?(seller)
  end

  # Platform-account (Gumroad-managed) sellers always pass — the platform account is US-based.
  # Unknown fails closed.
  def self.us_based_merchant_account?(seller)
    return true unless seller&.has_stripe_account_connected?

    seller.stripe_connect_account&.country == US_ALPHA2
  end

  # cart_product_currency: lowercase ISO code every cart item is priced in, nil for mixed-currency
  # or unknown carts. Only the forced-currency gate below reads it.
  #
  # cart_total_usd_cents: the PRE-tax, pre-discount item total (both callers pass the same one, so
  # the Element's method list and the deferred intent's resolve identically), nil when unknown. Only
  # the Klarna gate reads it, and nil fails closed there. Stripe enforces the window against the
  # intent's FINAL amount, which can drift out of it after the Element mounts — that is
  # Order::PreparePaymentIntentService#block_klarna_final_amount_outside_window's job, not this
  # input's.
  def initialize(sellers:, recurring: false, commission: false, setup_for_future: false, buyer_country: nil, ppp_discounted: false, cart_product_currency: nil, cart_total_usd_cents: nil, recurring_upi_registration: false)
    @sellers = sellers
    @recurring = recurring
    @commission = commission
    @setup_for_future = setup_for_future
    @buyer_country = buyer_country
    @ppp_discounted = ppp_discounted
    @cart_product_currency = cart_product_currency
    @cart_total_usd_cents = cart_total_usd_cents
    @recurring_upi_registration = recurring_upi_registration
  end

  def resolve
    @resolution ||= begin
      reason = ineligibility_reason
      eligible = eligible_method_policy
      payment_method_types = reason.nil? ? launched_method_set(eligible) : nil
      # Do not enable a new card-only recurring lane when UPI falls out of the acquisition gates.
      if reason.nil? && recurring_upi_registration && !payment_method_types.include?(UPI_PAYMENT_METHOD_TYPE)
        reason = "recurring_upi_unavailable"
        payment_method_types = nil
      end

      resolution = Resolution.new(
        client_confirm_eligible: reason.nil?,
        # Nil on Lane A carts: they never mount the client-confirmed Payment Element, so there is no
        # Stripe method list to hand them. Non-nil only when the cart confirms client-side.
        payment_method_types:,
        eligible_payment_method_types: eligible,
        fallback_reason: reason,
        stripe_connect_account_id: reason.nil? ? stripe_connect_account_id : nil
      )
      log_decision(resolution)
      resolution
    end
  end

  private
    attr_reader :sellers, :recurring, :commission, :setup_for_future, :buyer_country, :ppp_discounted, :cart_product_currency, :cart_total_usd_cents, :recurring_upi_registration

    # The client-confirm cart-shape gates, including the narrow recurring UPI exception, are applied
    # as an ordered set of reasons so a blocked cart records *why* it stayed on Lane A.
    def ineligibility_reason
      return "multi_seller" unless sellers.one?
      return "direct_charge_account_unlinked" if direct_charge_seller? && stripe_connect_account_id.blank?
      return "recurring_charge" if recurring && !recurring_upi_registration
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

      return %w[card upi] if recurring_upi_registration

      methods = ONE_TIME_PAYMENT_METHOD_TYPES
      methods -= RECURRING_INELIGIBLE_PAYMENT_METHOD_TYPES if recurring
      methods
    end

    # What Stripe actually receives: our policy decisions (launch gating, region gates,
    # forced-currency methods, the PPP matrix), then a final intersection with what the charged
    # ACCOUNT can accept. Keeping the capability check last is the whole relationship — policy never
    # needs to know about capabilities, or capabilities about policy.
    def launched_method_set(eligible)
      launched = eligible & LAUNCHED_PAYMENT_METHOD_TYPES
      launched += seller_opt_in_methods(eligible)
      forced = forced_currency_methods(eligible)
      launched += forced
      # Klarna and Alipay never join a forced-currency element mount: a surviving forced-currency
      # method means the Element and the deferred intent are in EUR/INR, but both gates below vet
      # only for the canonical-USD lane, so the two surfaces stay mutually exclusive.
      launched += klarna_methods(eligible) if forced.empty?
      launched += alipay_methods(eligible) if forced.empty?
      launched -= US_LOCKED_PAYMENT_METHOD_TYPES unless buyer_country == US_ALPHA2
      launched -= IN_LOCKED_PAYMENT_METHOD_TYPES unless buyer_country == IN_ALPHA2
      launched -= BR_LOCKED_PAYMENT_METHOD_TYPES unless buyer_country == BR_ALPHA2
      launched = ppp_method_matrix(launched) if ppp_discounted
      launched & account_supported_methods(launched)
    end

    # Added BEFORE the region gate / PPP matrix / capability intersection, so the opt-in re-adds ACH
    # only where it could already have been offered before the platform-wide withdrawal.
    def seller_opt_in_methods(eligible)
      return [] unless sellers.one? && sellers.first&.ach_payments_enabled?

      eligible & SELLER_OPT_IN_PAYMENT_METHOD_TYPES
    end

    # No Stripe-test-mode bypass, unlike the forced-currency methods: the flag is the QA switch too
    # (activate it for a QA seller), because a bypass would offer Klarna on every test-keyed checkout
    # regardless of the ramp decision. There is no recurring gate here — recurring carts have
    # already had klarna stripped from `eligible`.
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

    # No test-mode bypass, for the same reason as Klarna's. Two gates Klarna has and this
    # deliberately does not:
    #   - No buyer-country gate. Alipay is not region-locked, and the target cohort is largely NOT
    #     in mainland China (mainland buyer IPs were 12 sales in 30 days, while Chinese cards are
    #     used from Hong Kong, Taiwan and Singapore — gumroad-private#1339), so a GeoIP lock would
    #     gate out most of it.
    #   - No amount window. Stripe publishes no per-country Alipay transaction limits.
    def alipay_methods(eligible)
      return [] unless sellers.one?
      return [] unless eligible.include?(ALIPAY_PAYMENT_METHOD_TYPE)
      return [] unless alipay_supported_merchant_account?
      return [] unless Feature.active?(ALIPAY_LAUNCH_FEATURE, sellers.first)

      [ALIPAY_PAYMENT_METHOD_TYPE]
    end

    def klarna_supported_merchant_account?
      self.class.klarna_supported_merchant_account?(sellers.first)
    end

    def alipay_supported_merchant_account?
      self.class.alipay_supported_merchant_account?(sellers.first)
    end

    # What the account the PaymentIntent is created on can accept. Platform-account sellers accept
    # everything (we activate every launched method there); direct-charge sellers get their cached
    # capability snapshot. On a snapshot miss, fall back to card ONLY and refresh in the background —
    # checkout must never block on a live Stripe API call, and Link is deliberately not assumed
    # (absent on half of a live 40-account sample). One card-only checkout per uncached seller beats
    # gambling their (often first) sale on it.
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

    # Best-effort: the refresh only improves FUTURE checkouts, so a dead Redis must not fail THIS
    # one, whose methods are already resolved.
    def enqueue_availability_refresh(connect_account)
      RefreshMerchantAccountPaymentMethodAvailabilityWorker.perform_async(connect_account.id)
    rescue => e
      Rails.logger.error("Failed to enqueue payment method availability refresh for merchant account #{connect_account.id}: #{e.class} => #{e.message}")
    end

    # Live mode additionally requires the method's own launch flag
    # (Checkout::BuyerCurrencyEligibility::LOCAL_METHOD_LAUNCH_FEATURES, one per method so iDEAL can
    # ramp independently); test mode is the pre-launch QA surface.
    #
    # The cart-shape condition must mirror the presenter's method_forced_shape? gate: only a cart
    # priced uniformly in the forced currency mounts the Element in that currency, and a
    # forced-currency method listed on a USD element/intent makes Stripe reject the whole element
    # session — no payment form renders at all, which broke flag-on sellers' plain USD checkouts.
    def forced_currency_methods(eligible)
      return [] unless sellers.one? && Checkout::BuyerCurrencyEligibility.seller_enabled?(sellers.first)

      methods_for_cart_currency = (eligible & Checkout::BuyerCurrencyEligibility::FORCED_CURRENCY_PAYMENT_METHODS.keys).select do |method|
        Checkout::BuyerCurrencyEligibility.forced_currency_for(method) == cart_product_currency
      end
      return [] if methods_for_cart_currency.empty?

      # Registering a reusable UPI authorization has its own acquisition flag. Pulling it stops
      # new registrations while existing subscriptions continue through the renewal path.
      if recurring_upi_registration
        return [] unless Feature.active?(UPI_RECURRING_SERVICING_FEATURE)
        return [] unless Feature.active?(UPI_RECURRING_LAUNCH_FEATURE, sellers.first)

        methods_for_cart_currency &= [UPI_PAYMENT_METHOD_TYPE]
      end

      # Do not add a settlement-currency gate here. These carts are always priced wholly in the
      # forced currency (the select above), so the listed price is charged with no FX quote anywhere
      # and the charging account's balance currency cannot make it fail; account_supported_methods is
      # what establishes the account can take the method. Two narrower versions were tried and
      # reverted, both hiding methods from checkouts that could complete: gumroad-private#933 (iDEAL
      # disappeared platform-wide once the platform account settled EUR in EUR) and
      # gumroad-private#1442 (withheld from every EUR-settling Connect seller — most of the lane's
      # addressable volume).

      methods_for_cart_currency.select do |method|
        Checkout::BuyerCurrencyEligibility.stripe_test_mode? ||
          Checkout::BuyerCurrencyEligibility.local_method_launched?(method, sellers.first)
      end
    end

    # Methods with no Stripe-owned funding country (Link, Klarna, Alipay today; Afterpay/Affirm/
    # PayPal when they launch) are dropped by omission from both allowlists: `previewed_country`
    # returns nil for them, so the purchase would fail closed at prepare anyway. Klarna's US buyer
    # gate does not earn the region-locked allowance — it is a policy check on GeoIP, not a funding
    # country Stripe vouches for.
    def ppp_method_matrix(launched)
      launched & (PPP_VERIFIABLE_PAYMENT_METHOD_TYPES + PPP_REGION_LOCKED_PAYMENT_METHOD_TYPES)
    end

    def log_decision(resolution)
      launch_gated_out = resolution.eligible_payment_method_types - Array(resolution.payment_method_types)
      Rails.logger.info(
        "[#{self.class.name}] client_confirm_eligible=#{resolution.client_confirm_eligible} " \
        "seller_ids=#{sellers.map { _1&.id }} recurring=#{recurring} commission=#{commission} " \
        "setup_for_future=#{setup_for_future} buyer_country=#{buyer_country.inspect} " \
        "ppp_discounted=#{ppp_discounted} recurring_upi_registration=#{recurring_upi_registration} " \
        "fallback_reason=#{resolution.fallback_reason.inspect} " \
        "eligible=#{resolution.eligible_payment_method_types} enabled=#{resolution.payment_method_types.inspect} " \
        "launch_gated_out=#{launch_gated_out} stripe_connect_account_id=#{resolution.stripe_connect_account_id.inspect}"
      )
    end
end
