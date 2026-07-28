# frozen_string_literal: true

class Checkout::BuyerCurrencyEligibility
  include CurrencyHelper

  FEATURE_NAME = :buyer_currency_charging

  # The two per-seller rollout flags that decide whether a wallet (Apple Pay / Google Pay)
  # may pay a buyer-currency checkout. They live here, next to FEATURE_NAME, because this
  # service is what the charge path consults — the presenter reads the same constants for
  # its render-time decision, so the surface a buyer sees and the charge the server accepts
  # can never be gated on different flags.
  #
  # PAYMENT_ELEMENT_WALLETS_FEATURE_NAME is checkout's general "wallets render inside the
  # Payment Element" flag; WALLETS_FEATURE_NAME is this lane's own ramp, so wallets can be
  # pulled from buyer-currency checkouts alone without taking them off every other checkout.
  PAYMENT_ELEMENT_WALLETS_FEATURE_NAME = :payment_element_wallets
  WALLETS_FEATURE_NAME = :buyer_currency_wallets

  # Some local payment methods only work in a single currency: iDEAL and Bancontact
  # charges must be made in euros; UPI charges must be made in rupees. When a checkout wants one of these
  # methods, the payment method itself decides the presentment currency — there is
  # nothing to detect from the buyer's location. This registry maps each such
  # payment method (Stripe payment method type string) to the currency it forces.
  # To support a new forced-currency method, add it here.
  FORCED_CURRENCY_PAYMENT_METHODS = {
    "ideal" => Currency::EUR,
    "bancontact" => Currency::EUR,
    "upi" => Currency::INR,
    # Pix is Brazil's instant-payment scheme and Stripe only accepts it on BRL payment
    # intents — creating one in any other currency is rejected outright ("Payments with pix
    # support the following currencies: brl", verified against our live platform account).
    "pix" => Currency::BRL,
  }.freeze

  # Per-method production launch flags for the forced-currency local methods. Stripe test
  # mode keeps every registry method available for QA regardless of these flags; in live
  # mode a method is offered only when its own launch flag is active for the seller (on
  # top of the buyer-currency seller flags checked by seller_enabled?). Each method gets
  # its own flag so it can ramp and roll back independently — iDEAL first, then the rest
  # of the #5362 Phase 4 cohort.
  LOCAL_METHOD_LAUNCH_FEATURES = {
    "ideal" => :checkout_local_method_ideal,
    "bancontact" => :checkout_local_method_bancontact,
    "upi" => :checkout_local_method_upi,
    "pix" => :checkout_local_method_pix,
  }.freeze

  # `direct_listed_amount` is only set by the method-forced mode: true means the
  # product is already priced in the forced currency, so the charge path can use
  # the listed price as-is and skip fetching an FX quote. For the card mode
  # (#decision) it is always nil because that mode requires USD-priced products.
  Decision = Struct.new(:eligible, :currency, :fallback_reason, :direct_listed_amount, keyword_init: true) do
    def eligible?
      eligible
    end

    def direct_listed_amount?
      !!direct_listed_amount
    end
  end

  def self.forced_currency_for(payment_method)
    FORCED_CURRENCY_PAYMENT_METHODS[payment_method.to_s.downcase]
  end

  # Whether this registry method may charge live-mode checkouts for this seller. Test
  # mode is not consulted here — callers that also serve the QA surface should OR this
  # with stripe_test_mode?.
  def self.local_method_launched?(payment_method, seller)
    feature = LOCAL_METHOD_LAUNCH_FEATURES[payment_method.to_s.downcase]
    feature.present? && seller.present? && Feature.active?(feature, seller)
  end

  # Whether a method-forced surface for `currency` is available to card or Link in this
  # eligibility check: always in Stripe test mode, and in live mode when at least one
  # registry method forcing that currency has its launch flag active. The presenter and
  # prepare service independently require a capability-filtered resolver result before
  # mounting or charging this surface; this fallback gate only handles the non-registry
  # card/Link tokens that inherit the Element's currency.
  def self.forced_currency_surface_available?(currency:, seller:)
    return false if currency.blank?
    return true if stripe_test_mode?

    FORCED_CURRENCY_PAYMENT_METHODS.any? do |method, forced|
      forced == currency.to_s.downcase && local_method_launched?(method, seller)
    end
  end

  attr_reader :order, :seller, :merchant_account, :chargeable, :purchases, :params, :setup_future_charges, :off_session

  def self.seller_enabled?(seller)
    seller.present? &&
      Feature.active?(FEATURE_NAME, seller) &&
      Feature.active?(:buyer_local_currency, seller) &&
      !seller.disable_buyer_local_currency?
  end

  # Whether this seller's buyer-currency checkouts may take wallet payments at all. Seller must
  # be in the general Payment Element wallet rollout AND in this lane's own ramp; pulling either
  # flag stops wallets here, and pulling only the lane flag leaves every other checkout alone.
  def self.wallets_enabled?(seller)
    seller.present? &&
      Feature.active?(PAYMENT_ELEMENT_WALLETS_FEATURE_NAME, seller) &&
      Feature.active?(WALLETS_FEATURE_NAME, seller)
  end

  def self.buyer_presentment_display?(buyer_currency_display)
    return false if buyer_currency_display.blank?

    display_mode = buyer_currency_display[:display_mode] || buyer_currency_display["display_mode"]
    buyer_currency = buyer_currency_display[:buyer_currency_shown] || buyer_currency_display["buyer_currency_shown"]

    display_mode == "buyer_local" && buyer_currency.present?
  end

  def self.buyer_presentment_candidate?(seller:, buyer_currency_display:)
    seller_enabled?(seller) &&
      buyer_presentment_display?(buyer_currency_display)
  end

  def self.supported_merchant_account?(merchant_account)
    merchant_account.is_managed_by_gumroad? || merchant_account.is_a_stripe_connect_account?
  end

  def self.usd_settling_merchant_account?(merchant_account, presentment_currency:)
    return false unless usd_holding_merchant_account?(merchant_account)

    # Deliberately asked of the SELLER's account rather than the account the intent is
    # created on (unlike usd_holding_settlement_account?). This predicate guards the
    # FX-quote paths, and StripeFxQuote mints the quote with the seller's connected
    # account as `Stripe-Account`, so the seller's own settlement configuration is the
    # one that decides whether the quote is accepted.
    #
    # The stored currency answers the wrong question for accounts with Stripe
    # multi-currency settlement enabled: it mirrors Stripe's default_currency ("usd"),
    # but the payment intent's settlement currency can still differ per intent — and
    # Stripe configures it PER CURRENCY (e.g. the platform account settles EUR in EUR
    # since the iDEAL/SEPA capabilities were enabled, while every other currency still
    # settles in USD). Stripe's rejection of an FX quote or intent is the only reliable
    # signal, and once observed it is recorded on the merchant account for that
    # presentment currency — while that marker is fresh, skip the doomed FX-quote round
    # trip for that currency (up to 2s of checkout latency, on every visit) and fall
    # back to canonical USD immediately. Other currencies keep quoting.
    !merchant_account.settlement_currency_mismatch_active?(presentment_currency)
  end

  # The weaker of the two settlement questions: does the account HOLD its balance in USD
  # (per our stored mirror of Stripe's default_currency)? Unlike
  # usd_settling_merchant_account? this deliberately ignores the learned
  # settlement-currency-mismatch marker, because the marker only says "an FX quote to USD
  # for this currency will be rejected" — it does not make a plain forced-currency charge
  # fail. The direct-listed-amount forced lane (an EUR-priced product paid with iDEAL)
  # never mints an FX quote, so the marker is irrelevant to it; gating that lane on the
  # marker is exactly what turned iDEAL dark platform-wide on 2026-07-23 (enabling the
  # iDEAL/SEPA capabilities made the platform account settle EUR in EUR, the EUR marker
  # was recorded, and every Gumroad-managed seller lost the iDEAL tab —
  # gumroad-private#933).
  def self.usd_holding_merchant_account?(merchant_account)
    merchant_account.currency.blank? || merchant_account.currency.to_s.downcase == Currency::USD
  end

  # The account a PaymentIntent for this seller is actually CREATED on — which is the
  # account whose settlement currency Stripe applies to the intent.
  #
  # Gumroad charges sellers two different ways (see StripeChargeProcessor):
  #
  #   Stripe Connect sellers (direct charges): the intent is created ON the seller's own
  #   connected account, so that account's settlement currency is the one that matters.
  #
  #   Everyone else (destination charges): the intent is created on the GUMROAD PLATFORM
  #   account, which holds USD, and the seller's account only appears as
  #   `transfer_data[destination]` — it receives a transfer after the charge settles. The
  #   destination account's own balance currency does not constrain what currency the
  #   intent may be created in, so reading it here withholds payment methods a checkout
  #   could complete perfectly well. Reading it hid UPI from the seller in
  #   gumroad-private#1409 — an Indian seller pricing in rupees for an Indian buyer, the
  #   exact shape UPI exists for.
  #
  # Returns nil only if the platform account row is missing, which callers treat as
  # "cannot verify settlement" and fail closed.
  def self.settlement_merchant_account(merchant_account)
    return merchant_account if merchant_account.blank? || merchant_account.is_a_stripe_connect_account?

    MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id)
  end

  # usd_holding_merchant_account? asked of the account the intent is created on, rather
  # than of whichever account happens to be attached to the purchase. See
  # settlement_merchant_account above for why those differ for destination charges.
  def self.usd_holding_settlement_account?(merchant_account)
    settlement_account = settlement_merchant_account(merchant_account)
    return false if settlement_account.blank?

    usd_holding_merchant_account?(settlement_account)
  end

  def self.stripe_test_mode?
    Stripe.api_key.to_s.start_with?("sk_test_")
  end

  def initialize(order:, seller:, merchant_account:, chargeable:, purchases:, params:, setup_future_charges:, off_session:)
    @order = order
    @seller = seller
    @merchant_account = merchant_account
    @chargeable = chargeable
    @purchases = purchases
    @params = params || {}
    @setup_future_charges = setup_future_charges
    @off_session = off_session
  end

  def decision
    return fallback(:feature_disabled) unless self.class.seller_enabled?(seller)
    return fallback(:unsupported_processor) unless merchant_account&.stripe_charge_processor?
    return fallback(:unsupported_charge_model) unless supported_charge_model?
    return fallback(:wallet_payment_request) if wallet_type.present? && !wallet_lane_allowed?
    return fallback(:future_charge_setup) if setup_future_charges
    return fallback(:off_session) if off_session
    return fallback(:no_purchases) if purchases.empty?
    # This service sees the purchases of ONE charge (the order pipeline groups purchases
    # into one charge per seller before charging), so an order spanning several sellers
    # spans several charges — but the quote the buyer confirmed locked the whole cart
    # total for a single PaymentIntent. Splitting one locked quote across several intents
    # is Open Question 9 on issue #5419, so those orders fall back (and fail closed in
    # Charge::CreateService when a quote token is present).
    return fallback(:multi_seller_checkout) if multi_seller_order?
    return fallback(:missing_stripe_chargeable) if chargeable&.get_chargeable_for(StripeChargeProcessor.charge_processor_id).blank?

    # The verified quote locked the cart total, so every purchase on the charge must
    # individually support presentment — one unsupported item invalidates the whole cart.
    # The gates here must mirror BuyerCurrencyQuote#quotable_product?: the quote token
    # binds only seller, currency, and total (not product ids), so a stale token issued
    # for a supported cart could otherwise be replayed against an unsupported product
    # whose charged amount differs from the locked total.
    purchases.each do |purchase|
      return fallback(:unsupported_product_type) if unsupported_product_type?(purchase)
      return fallback(:unsupported_product_type) if unquotable_product?(purchase.link)
      return fallback(:unsupported_product_currency) unless purchase.link.price_currency_type.to_s.downcase == Currency::USD
    end

    # All purchases in an order come from the same checkout request, so any purchase's IP
    # identifies the buyer's location.
    buyer_currency = buyer_currency_for_ip(purchases.first.ip_address)
    return fallback(:missing_buyer_currency) if buyer_currency.blank?
    return fallback(:canonical_buyer_currency) if buyer_currency == Currency::USD
    return fallback(:unsupported_buyer_currency) unless StripeChargeProcessor.charge_minor_units_compatible?(buyer_currency)
    # Checked here (not up top with the other account gates) because the settlement
    # mismatch marker is scoped to the presentment currency, which isn't known earlier.
    return fallback(:unsupported_settlement_currency) unless usd_settling_merchant_account?(buyer_currency)

    eligible(currency: buyer_currency)
  end

  # Second eligibility entry point, sitting beside the GeoIP-driven card mode above
  # (it does not replace it). Answers: "this checkout must present in `forced_currency`
  # (by default, the currency payment method `payment_method` forces — e.g. "eur" for
  # "ideal") — may we, and is the product already priced in it?"
  #
  # Unlike the card mode there is NO canonical-USD fallback here: an ineligible
  # result means the payment method must not be offered for this checkout at all,
  # because the method physically cannot charge in USD. The caller reads
  # `fallback_reason` only to learn why the method was withheld.
  #
  # `forced_currency` can be passed explicitly for methods that do not themselves force
  # a currency (card/Link) when they are picked on a Payment Element that was MOUNTED in
  # a forced currency: the ConfirmationToken inherits the element's currency, so the
  # intent must be created in it no matter which method the buyer chose. The presenter
  # only mounts a forced-currency element for carts priced uniformly in that currency
  # (method_forced_shape?), so these checkouts land in the direct-listed-amount case.
  #
  # This mode intentionally does not look at the buyer's GeoIP location or at the
  # buyer_currency_display params — the payment method (or the element mount currency
  # derived from the product's pricing) alone fixes the currency.
  def method_forced_decision(payment_method:, forced_currency: nil)
    forced_currency ||= self.class.forced_currency_for(payment_method)
    # A method not in the registry has no forced currency, so this mode has
    # nothing to decide — the caller should not offer it through this path.
    return fallback(:unsupported_payment_method) if forced_currency.blank?

    return fallback(:feature_disabled) unless self.class.seller_enabled?(seller)
    # Live mode is no longer a blanket refusal: each registry method carries its own
    # per-method launch flag (LOCAL_METHOD_LAUNCH_FEATURES) so the #5362 Phase 4 cohort
    # can ramp one method at a time — iDEAL first. Test mode keeps the whole registry
    # available for QA. Card/Link tokens minted on a forced-currency element carry no
    # registry entry of their own; they are allowed whenever the surface that mounted
    # the element is available (some launched method forces the element's currency).
    return fallback(:method_not_launched) unless method_forced_mode_allowed?(payment_method, forced_currency)
    return fallback(:unsupported_processor) unless merchant_account&.stripe_charge_processor?
    return fallback(:unsupported_charge_model) unless supported_forced_currency_charge_model?
    # Only the stored-currency (USD-holding) half of the settlement question is a
    # blanket gate here. The learned per-currency mismatch marker is NOT: it predicts
    # FX-quote rejection, which only matters on the quoted (USD-priced) case below.
    # The direct-listed-amount case charges the listed price with no FX quote at all,
    # and the marker being set for the forced currency is in fact the EXPECTED state
    # once that method's capabilities make the account settle the currency in itself
    # (2026-07-23 iDEAL dark-ramp, gumroad-private#933) — so it must not withhold the
    # method.
    #
    # The question is asked of the account the intent is CREATED on, which for a
    # destination charge is the Gumroad platform account, not the seller's own account
    # (see settlement_merchant_account). Asking it of the seller's account instead used
    # to hide UPI from every seller whose Stripe balance settles in rupees — the exact
    # seller UPI exists for (gumroad-private#1409).
    return fallback(:unsupported_settlement_currency) unless self.class.usd_holding_settlement_account?(merchant_account)
    return fallback(:future_charge_setup) if setup_future_charges
    return fallback(:off_session) if off_session
    return fallback(:no_purchases) if purchases.empty?

    product_currencies = []
    purchases.each do |purchase|
      return fallback(:unsupported_product_type) if unsupported_product_type?(purchase)

      product_currency = purchase.link.price_currency_type.to_s.downcase
      product_currencies << product_currency
      # Multi-line forced-currency presentment is currently limited to the direct-listed-amount
      # case, where every line is already priced in the forced currency and no FX quote is needed.
      # USD-priced single-line checkouts keep the existing quote path; mixed direct/quoted carts need
      # the per-line quote basis tracked in gumroad-private#1298 before they can be safe.
      unless product_currency == forced_currency || (purchases.one? && product_currency == Currency::USD)
        return fallback(:unsupported_product_currency)
      end
    end

    priced_in_forced_currency = product_currencies.all? { _1 == forced_currency }

    # The USD-priced case converts through a Stripe FX quote (forced currency -> USD),
    # which is exactly the call a fresh mismatch marker predicts Stripe will reject —
    # and unlike the card path there is no graceful USD fallback for a method that can
    # only charge in its forced currency. Withhold the method rather than render a tab
    # that fails at prepare. The direct-listed-amount case skips this on purpose: it
    # never mints a quote (see the settlement comment above).
    if !priced_in_forced_currency && !usd_settling_merchant_account?(forced_currency)
      return fallback(:unsupported_settlement_currency)
    end

    # Defensive guard for future registry entries: Gumroad and Stripe must agree
    # on the currency's minor units before we can charge in it (EUR always
    # passes; this protects against someone adding e.g. a KRW-forced method).
    return fallback(:unsupported_forced_currency) unless StripeChargeProcessor.charge_minor_units_compatible?(forced_currency)

    eligible(currency: forced_currency, direct_listed_amount: priced_in_forced_currency)
  end

  private
    def eligible(currency:, direct_listed_amount: nil)
      Decision.new(eligible: true, currency:, fallback_reason: nil, direct_listed_amount:)
    end

    def fallback(reason)
      Decision.new(eligible: false, currency: nil, fallback_reason: reason)
    end

    def stripe_test_mode?
      self.class.stripe_test_mode?
    end

    # See the launch-flag comment in #method_forced_decision. Registry methods gate on
    # their own launch flag in live mode; non-registry methods (card/Link on a
    # forced-currency element) gate on the element surface being available at all.
    def method_forced_mode_allowed?(payment_method, forced_currency)
      return true if stripe_test_mode?

      if self.class.forced_currency_for(payment_method).present?
        self.class.local_method_launched?(payment_method, seller)
      else
        self.class.forced_currency_surface_available?(currency: forced_currency, seller:)
      end
    end

    def usd_settling_merchant_account?(presentment_currency)
      self.class.usd_settling_merchant_account?(merchant_account, presentment_currency:)
    end

    def supported_charge_model?
      self.class.supported_merchant_account?(merchant_account)
    end

    # The forced-currency lane's charge-model gate. Broader than supported_charge_model?
    # (which the card lane keeps) by exactly one case: a seller with a Gumroad-managed
    # Stripe Custom account.
    #
    # That seller is charged with a DESTINATION charge — StripeChargeProcessor creates
    # the PaymentIntent on the Gumroad platform account and passes their account as
    # `transfer_data[destination]` — which is the same intent shape as a seller with no
    # Stripe account at all, and that case is already supported here. The two are
    # indistinguishable from Stripe's point of view, so treating one as unsupported only
    # withheld local payment methods from checkouts that could complete.
    #
    # The card lane is deliberately NOT widened: it converts through an FX quote minted
    # against the seller's own account, so the seller's account model genuinely matters
    # there. This lane charges the product's listed price in the currency it is already
    # priced in (or quotes separately, guarded by usd_settling_merchant_account?).
    def supported_forced_currency_charge_model?
      return false if merchant_account.blank?

      merchant_account.is_a_stripe_connect_account? ||
        self.class.settlement_merchant_account(merchant_account)&.is_managed_by_gumroad? || false
    end

    # True when this wallet payment is one the server is willing to price in the buyer's
    # currency. Two conditions, and both are things the client cannot assert for itself:
    #
    #   1. The seller is in both wallet rollout flags. Without this the kill switch is
    #      render-time only — a checkout page loaded while the flags were on would keep its
    #      wallet rows and still complete a buyer-currency wallet charge after the flags were
    #      pulled, which is exactly what an emergency ramp-down needs to stop.
    #
    #   2. The wallet came from the Payment Element, not the deprecated Payment Request
    #      Button. The element's wallet sheet quotes the locked buyer-currency total the cart
    #      shows (both are mounted from the same FX quote), while the Payment Request Button's
    #      sheet is built from the canonical USD total — charging that buyer in local currency
    #      would charge an amount they never saw. The Payment Request Button cannot reach this
    #      path today (it is suppressed at render and selecting it withholds the quote token),
    #      so this is the server-side backstop for a client that stops honoring either rule.
    #
    # PurchasePaymentFlow#payment_details_source_for treats the same param as the wallet
    # surface signal, so the recorded surface and the charge decision read one input.
    def wallet_lane_allowed?
      self.class.wallets_enabled?(seller) &&
        params[:payment_details_source] == PurchasePaymentFlow::PAYMENT_ELEMENT
    end

    def wallet_type
      params[:wallet_type]
    end

    # True when the order's purchases span more than one seller — i.e. the order produces
    # more than one prospective charge. Checked against the whole order, not just this
    # charge's purchases (which are single-seller by construction).
    def multi_seller_order?
      order.present? && order.purchases.map(&:seller_id).uniq.many?
    end

    # Commission deposits and installment payments charge less than the locked cart total
    # (issue #5419 excludes both from Phase 1), so they must fall back even when a valid
    # quote token reaches the charge path.
    def unsupported_product_type?(purchase)
      purchase.is_commission_deposit_purchase? ||
        purchase.is_installment_payment? ||
        purchase.link.native_type == Link::NATIVE_TYPE_COMMISSION
    end

    # Charge-time mirror of the product-shape gates BuyerCurrencyQuote#quotable_product?
    # applies at quote time. Preorders, subscriptions, free trials, and products offering
    # an installment plan all charge an amount that can differ from the locked cart total
    # (nothing now, a first period, $0, or a first installment), so a quote replayed
    # against them must fall back instead of being honored. Only the card-mode #decision
    # uses this — the method-forced lane (iDEAL/Bancontact) has no locked cart quote.
    def unquotable_product?(product)
      product.is_in_preorder_state? ||
        product.is_recurring_billing? ||
        product.free_trial_enabled? ||
        product.installment_plan.present?
    end
end
