# frozen_string_literal: true

class Checkout::BuyerCurrencyEligibility
  include CurrencyHelper

  FEATURE_NAME = :buyer_currency_charging

  # Shared with the presenter so wallets render and charge on the same flags.
  # PAYMENT_ELEMENT_WALLETS is checkout-wide; WALLETS is this lane's ramp so we
  # can pull wallets here without taking them off every other checkout.
  PAYMENT_ELEMENT_WALLETS_FEATURE_NAME = :payment_element_wallets
  WALLETS_FEATURE_NAME = :buyer_currency_wallets

  # Per-seller ramp for quoting DESTINATION charges (Custom account: PI on the
  # platform, seller only in transfer_data[destination]). Separate from FEATURE_NAME
  # because it widens the charge model on a live money path. Custom accounts have
  # a user, so they fail is_managed_by_gumroad? ("this row has no user") and never
  # reached the FX lane without this flag.
  DESTINATION_CHARGE_FEATURE_NAME = :buyer_currency_destination_charges

  # Per-seller ramp for charging a product's listed currency directly when it is already
  # the buyer's currency. This lane mints no FX quote: the product price is already in the
  # currency the buyer saw, and only USD-stored tax/shipping components are converted back
  # with the purchase's stored rate.
  LISTED_CURRENCY_DIRECT_CHARGE_FEATURE_NAME = :checkout_listed_currency_direct_charge

  # Memberships get their own ramp because the buyer-currency amount outlives checkout.
  # Pulling it stops new memberships; renewals keep billing the stored fixed amount.
  SUBSCRIPTION_FEATURE_NAME = :buyer_currency_subscriptions

  # Some local payment methods force their own currency: iDEAL/Bancontact use EUR,
  # UPI uses INR, and Pix uses BRL. The method, not buyer location, decides the
  # presentment currency.
  FORCED_CURRENCY_PAYMENT_METHODS = {
    "ideal" => Currency::EUR,
    "bancontact" => Currency::EUR,
    "upi" => Currency::INR,
    # Pix is Brazil's instant-payment scheme and Stripe only accepts it on BRL payment
    # intents — creating one in any other currency is rejected outright ("Payments with pix
    # support the following currencies: brl", verified against our live platform account).
    "pix" => Currency::BRL,
  }.freeze

  # Live-mode launch flags for forced-currency methods. Test mode keeps every
  # registry method available for QA; live mode requires the method's own seller
  # flag, so each method can ramp and roll back independently.
  LOCAL_METHOD_LAUNCH_FEATURES = {
    "ideal" => :checkout_local_method_ideal,
    "bancontact" => :checkout_local_method_bancontact,
    "upi" => :checkout_local_method_upi,
    "pix" => :checkout_local_method_pix,
  }.freeze

  # `direct_listed_amount` is set when every product is already priced in the charge
  # currency, so the charge path can use the listed price as-is and skip fetching an FX
  # quote.
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

  def self.listed_currency_direct_charge_enabled?(seller)
    seller.present? && Feature.active?(LISTED_CURRENCY_DIRECT_CHARGE_FEATURE_NAME, seller)
  end

  def self.direct_listed_line_items_eligible?(line_items:, buyer_currency:)
    return false if line_items.blank?

    currency = buyer_currency.to_s.downcase
    return false if currency.blank? || currency == Currency::USD
    return false unless StripeChargeProcessor.charge_minor_units_compatible?(currency)
    return false if line_items.any? { _1.product.blank? }
    return false unless line_items.all? { _1.product.price_currency_type.to_s.downcase == currency }

    seller_ids = line_items.map { _1.product.user_id }.uniq
    return false unless seller_ids.one?

    seller = line_items.first.product.user
    return false unless seller_enabled?(seller)
    return false unless listed_currency_direct_charge_enabled?(seller)
    return false if line_items.any? { _1.later_charge_kind.present? }
    return false if line_items.any? { _1.tip_cents.to_i.positive? || _1.shipping_cents.to_i.positive? }

    rates = line_items.map { _1.listed_currency_rate.presence }
    rates.all? && rates.map(&:to_s).uniq.one? && rates.first.to_d.positive?
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

  attr_reader :order, :seller, :merchant_account, :chargeable, :purchases, :params, :setup_future_charges, :off_session, :client_confirm

  def self.seller_enabled?(seller)
    seller.present? &&
      Feature.active?(FEATURE_NAME, seller) &&
      Feature.active?(:buyer_local_currency, seller) &&
      !seller.disable_buyer_local_currency?
  end

  # Own ramp on top of seller_enabled?: a membership amount outlives checkout.
  # Pulling the flag stops NEW memberships; existing ones keep billing the stored
  # amount (renewal checks processor + stored-row facts, not this flag).
  def self.subscriptions_enabled?(seller)
    seller.present? &&
      seller_enabled?(seller) &&
      Feature.active?(SUBSCRIPTION_FEATURE_NAME, seller)
  end

  def self.indian_card_mandate_presentment_supported?(seller:, merchant_account:, currency:)
    return true unless seller.present? && Feature.active?(StripeChargeProcessor::INDIA_CARD_MANDATE_RELIABILITY_FEATURE, seller)
    return true if StripeIntentChargeRouting.direct_charge_account?(merchant_account)

    StripeChargeProcessor.indian_card_mandate_currency_supported?(currency)
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

    return false if display_mode != "buyer_local" || buyer_currency.blank?

    # A USD display is not presentment. A product priced in another currency shows a converted
    # USD price to a US buyer, and that is simply the amount the charge already uses, so no
    # quote is minted for it (#decision falls back on :canonical_buyer_currency, and
    # BuyerCurrencyQuote returns nothing). Treating it as a candidate would only cost the buyer
    # their wallet buttons, which callers disable whenever the cart displays a presentment total.
    buyer_currency.to_s.downcase != Currency::USD
  end

  def self.buyer_presentment_candidate?(seller:, buyer_currency_display:)
    seller_enabled?(seller) &&
      buyer_presentment_display?(buyer_currency_display)
  end

  # Whether this seller may quote a DESTINATION charge in the buyer's currency. See
  # DESTINATION_CHARGE_FEATURE_NAME. When this is false everything below behaves exactly
  # as it did before the flag existed.
  def self.destination_charge_quotes_enabled?(seller)
    seller.present? && Feature.active?(DESTINATION_CHARGE_FEATURE_NAME, seller)
  end

  # Quotes must be minted on the account that creates the PaymentIntent. For
  # destination charges that is the platform account, not the seller's Custom
  # account. Do not gate this on DESTINATION_CHARGE_FEATURE_NAME: forced-currency
  # methods already create destination charges and need the same routing.
  def self.fx_quote_merchant_account(merchant_account)
    settlement_merchant_account(merchant_account)
  end

  # Quotes must declare the intent's transfer_data[destination]; missing or extra
  # destination is a charge-time failure. Only Gumroad-managed Custom accounts
  # produce a transfer destination, and forced-currency methods already use it.
  def self.fx_quote_destination_account_id(merchant_account)
    return nil if merchant_account.blank?
    return nil if merchant_account.is_a_stripe_connect_account?
    return nil if merchant_account.user.blank?

    merchant_account.charge_processor_merchant_id.presence
  end

  def self.supported_merchant_account?(merchant_account, seller: nil)
    return false if merchant_account.blank?

    merchant_account.is_managed_by_gumroad? ||
      merchant_account.is_a_stripe_connect_account? ||
      (destination_charge_quotes_enabled?(seller) &&
        settlement_merchant_account(merchant_account)&.is_managed_by_gumroad?) ||
      false
  end

  def self.usd_settling_merchant_account?(merchant_account, presentment_currency:, seller: nil)
    # Ask the account that mints the quote. For destination charges, the later
    # transfer to the seller is a separate conversion no FX quote covers.
    quote_account = fx_quote_merchant_account(merchant_account)
    return false unless usd_holding_merchant_account?(quote_account)

    # Stored currency is Stripe's default, not per-intent settlement. A fresh
    # mismatch marker means Stripe already rejected this currency, so skip that
    # FX round trip while other currencies keep quoting.
    !quote_account&.settlement_currency_mismatch_active?(presentment_currency)
  end

  # Only asks whether the default balance is USD. Ignore the FX-quote mismatch
  # marker: forced-currency direct-listed charges mint no quote, so that marker
  # must not darken methods like iDEAL.
  def self.usd_holding_merchant_account?(merchant_account)
    return false if merchant_account.blank?

    merchant_account.currency.blank? || merchant_account.currency.to_s.downcase == Currency::USD
  end

  # Account that creates the PaymentIntent: Stripe Connect charges use the seller
  # account; destination charges use the platform account and transfer afterward.
  # Returns nil only if the platform account row is missing.
  def self.settlement_merchant_account(merchant_account)
    return merchant_account if merchant_account.blank? || merchant_account.is_a_stripe_connect_account?

    MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id)
  end

  def self.stripe_test_mode?
    Stripe.api_key.to_s.start_with?("sk_test_")
  end

  def initialize(order:, seller:, merchant_account:, chargeable:, purchases:, params:, setup_future_charges:, off_session:, client_confirm: false)
    @order = order
    @seller = seller
    @merchant_account = merchant_account
    @chargeable = chargeable
    @purchases = purchases
    @params = params || {}
    @setup_future_charges = setup_future_charges
    @off_session = off_session
    @client_confirm = client_confirm
  end

  def decision
    return fallback(:feature_disabled) unless self.class.seller_enabled?(seller)
    return fallback(:unsupported_processor) unless merchant_account&.stripe_charge_processor?
    return fallback(:unsupported_charge_model) unless supported_charge_model?
    return fallback(:wallet_payment_request) if wallet_type.present? && !wallet_lane_allowed?
    # `setup_future_charges` means this checkout is also saving the card for later use. It
    # is a fallback because a saved card implies a later off-session charge. Products in the
    # later-charge ramp are the exception: their agreed amount is stored for reuse. A one-off
    # "save my card" checkout and mixed carts still fall back.
    return fallback(:future_charge_setup) if setup_future_charges && !later_charge_setup_in_ramp?
    return fallback(:no_purchases) if purchases.empty?
    # Off-session means no buyer is available to answer an authentication challenge, so by
    # default presentment falls back: the amount would be re-derived from today's rate for a
    # buyer who is not there to agree to it. Two shapes are exempt, for different reasons.
    #
    # A multi-seller cart is off-session by construction: the browser collects a reusable
    # payment method once, then each seller's charge is confirmed server-side against it. The
    # buyer IS at the keyboard — they just pressed pay — and they pressed it against the sum
    # of the locked per-charge amounts, so presentment is safe there.
    #
    # A subscription renewal has no buyer present at all, but it does not need one: it charges
    # the amount stored when the member signed up, never one re-derived now, so there is
    # nothing new for them to agree to (see #subscription_renewal_with_stored_amount?, which
    # returns false when no stored amount exists).
    #
    # Any other off-session charge — a preorder release, a renewal that stored no amount —
    # still falls back.
    return fallback(:off_session) if off_session && !multi_seller_order? && !subscription_renewal_with_stored_amount?
    return fallback(:missing_stripe_chargeable) if !client_confirm && chargeable&.get_chargeable_for(StripeChargeProcessor.charge_processor_id).blank?

    # The submitted quote token carries the currency the buyer actually confirmed — with the
    # checkout picker that can differ from GeoIP's answer for this IP, and verify! holds the
    # token to ITS currency, so gating on GeoIP here would reject the buyer's own valid token.
    # A missing or tampered token falls back to GeoIP; verify! still rejects tampered tokens.
    #
    # All purchases in an order come from the same checkout request, so any purchase's IP
    # identifies the buyer's location.
    buyer_currency = Checkout::BuyerCurrencyQuote.quoted_currency_hint(params[:buyer_currency_quote].presence) ||
      buyer_currency_for_ip(purchases.first.ip_address)
    return fallback(:missing_buyer_currency) if buyer_currency.blank?
    return fallback(:canonical_buyer_currency) if buyer_currency == Currency::USD
    return fallback(:unsupported_buyer_currency) unless StripeChargeProcessor.charge_minor_units_compatible?(buyer_currency)
    if purchases.any? { _1.link.is_recurring_billing? } &&
       !self.class.indian_card_mandate_presentment_supported?(seller:, merchant_account:, currency: buyer_currency)
      return fallback(:unsupported_indian_card_mandate_currency)
    end

    # The verified quote locked the cart total, so every purchase on the charge must
    # individually support presentment — one unsupported item invalidates the whole cart.
    # The gates here must mirror BuyerCurrencyQuote#quotable_line_item?: the quote token
    # binds only seller, currency, and total (not product ids), so a stale token issued
    # for a supported cart could otherwise be replayed against an unsupported product
    # whose charged amount differs from the locked total.
    listed_in_buyer_currency = []
    purchases.each do |purchase|
      return fallback(:unsupported_product_type) if unsupported_product_type?(purchase) && !later_charge_purchase_in_ramp?(purchase)
      return fallback(:unsupported_product_type) if unquotable_purchase?(purchase)

      listed_in_buyer_currency << (purchase.link.price_currency_type.to_s.downcase == buyer_currency)
    end

    # Listed-amount lane: every line is already the buyer's currency and can be charged as
    # listed cents. A mixed listing cart is still one USD basis (gumroad-private#1433) — quote
    # the whole cart into the buyer currency instead of falling presentment back to USD.
    if listed_in_buyer_currency.any?
      listed_lane = listed_in_buyer_currency.all? &&
        # The snapshotted currency, not the product's current one: a seller who repriced into
        # the buyer's currency later would otherwise get USD cents sent as the buyer's.
        purchases.all? { _1.displayed_price_currency_type.to_s.downcase == buyer_currency } &&
        # One ConfirmationToken funds one PaymentIntent, so a cart spanning sellers cannot
        # charge listed amounts and falls back to canonical USD per seller.
        purchases.all? { _1.seller_id == seller.id } &&
        !multi_seller_order? &&
        self.class.listed_currency_direct_charge_enabled?(seller) &&
        listed_currency_displayed?(buyer_currency) &&
        purchases.none? { Purchase::FixLaterChargePresentmentService.kind_for(_1).present? } &&
        purchases.none? { _1.tip&.value_cents.to_i.positive? || _1.shipping_cents.to_i.positive? } &&
        listed_lane_rates_uniform?(purchases)

      if listed_lane
        return eligible(currency: buyer_currency, direct_listed_amount: true)
      end

      # All-listed but not listed-lane (flag off, tip, shipping, later-charge). Mixed
      # listing falls through to the quote-lane gates below so it cannot skip them.
      return fallback(:listed_currency_is_buyer_currency) if listed_in_buyer_currency.all?
    end

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
    # No settlement gate applies to this lane as a whole. The only settlement question
    # left is asked further down, and only of the quoted (USD-priced) case, which is the
    # one that actually needs a Stripe FX quote to succeed.
    #
    # The direct-listed-amount case — an EUR-priced product paid with iDEAL or Bancontact,
    # an INR-priced product paid with UPI — charges the product's listed price in the
    # currency it is already priced in. There is no FX quote anywhere in that flow, so
    # nothing about the charging account's balance currency can make it fail: Stripe
    # accepts a EUR intent on an account whose balance is EUR (indeed that is the simplest
    # case — the payment settles natively with no conversion at all), and the per-account
    # capability intersection in Checkout::PaymentMethodResolver separately guarantees the
    # account has the method activated. Requiring the charging account to HOLD US dollars
    # was inherited from the FX-quote lane, where it genuinely matters, and it was the last
    # thing capping this lane: it withheld iDEAL/Bancontact from every Stripe Connect seller
    # settling in euros — precisely the sellers those methods exist for (gumroad-private#1442).
    #
    # Gumroad's own ledger stays correct without it. For a Stripe Connect seller the money
    # never passes through a Gumroad-held balance at all: the charge lands directly in the
    # seller's own Stripe account, and Purchase#increment_sellers_balance! /
    # #process_refund_or_chargeback_for_purchase_balance both return early unless
    # `charged_using_gumroad_merchant_account?` (Purchase#1178), so no seller Balance row in
    # any currency is written for these charges — there is nothing for a non-USD settlement
    # currency to corrupt. Payouts for such sellers are made by Stripe itself, not by us.
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
    def listed_currency_displayed?(currency)
      params[:payment_details_source] == PurchasePaymentFlow::PAYMENT_ELEMENT &&
        params[:payment_element_mount_currency].to_s.downcase == currency
    end

    # Charge::DirectListedPresentment allocates the charge-level Gumroad amount per purchase
    # using each purchase's stored rate, so split rates would allocate against two bases.
    # Same-currency lines normally share one rate; if they don't, fall back rather than pick.
    def listed_lane_rates_uniform?(purchases)
      rates = purchases.map { _1.rate_converted_to_usd.presence }
      rates.all? && rates.map(&:to_s).uniq.one? && rates.first.to_d.positive?
    end

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
      self.class.usd_settling_merchant_account?(merchant_account, presentment_currency:, seller:)
    end

    def supported_charge_model?
      self.class.supported_merchant_account?(merchant_account, seller:)
    end

    # The forced-currency lane's charge-model gate.
    #
    # A seller with a Gumroad-managed Stripe Custom account is charged with a DESTINATION
    # charge — StripeChargeProcessor creates the PaymentIntent on the Gumroad platform
    # account and passes their account as `transfer_data[destination]` — which is the same
    # intent shape as a seller with no Stripe account at all. The two are indistinguishable
    # from Stripe's point of view, so treating one as unsupported only withheld local
    # payment methods from checkouts that could complete.
    #
    # This gate does not consult the destination-charge ramp flag, unlike the card lane's
    # supported_charge_model?. This lane has supported destination charges since #1409 and
    # is already live; the flag exists to ramp the card lane's FX-quote path, which is the
    # part that was never exercised for this charge model.
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

    # `setup_future_charges` is set for several unrelated reasons (Order::ChargeService:57
    # ORs together a buyer ticking "save my card" and several later-charge products), so the
    # purchase shape must prove that every saved card has an agreed amount to store.
    def later_charge_setup_in_ramp?
      return false if purchases.blank?
      return false unless self.class.subscriptions_enabled?(seller)

      purchases.all? do |purchase|
        later_charge_purchase_in_ramp?(purchase)
      end
    end

    # Kept as an alias while rolling code and specs still use the membership-specific name.
    alias_method :subscription_setup_in_ramp?, :later_charge_setup_in_ramp?

    def later_charge_purchase_in_ramp?(purchase)
      return false unless self.class.subscriptions_enabled?(seller)
      return false if purchase.link.free_trial_enabled?

      purchase.link.is_recurring_billing? ||
        purchase.is_installment_payment? ||
        purchase.is_commission_deposit_purchase? ||
        purchase.is_preorder_authorization?
    end

    # True only for a renewal that already has a stored fixed amount to charge.
    #
    # This is what makes the off_session lift safe. A renewal must charge the amount stored
    # at signup, never one re-derived from today's rate — so if the stored row is missing
    # (subscription signed up before the ramp, or the flag was off at signup) the renewal
    # must keep falling back to canonical USD rather than invent a buyer-currency amount the
    # member never agreed to. Deliberately does NOT consult the ramp flag: a subscription
    # that stored an amount keeps charging it even if the flag is later pulled, because the
    # alternative is silently switching an existing member's currency mid-subscription.
    def subscription_renewal_with_stored_amount?
      return false if purchases.blank?
      return false unless purchases.one?

      subscription = purchases.first.subscription
      subscription.present? && subscription.current_later_charge_presentment.present?
    end

    # These shapes remain unsupported by the method-forced lane. The card quote lane lifts
    # them separately once it has signed both today's charge and the later amount.
    def unsupported_product_type?(purchase)
      purchase.is_commission_deposit_purchase? ||
        purchase.is_installment_payment? ||
        purchase.link.native_type == Link::NATIVE_TYPE_COMMISSION
    end

    # Charge-time mirror of BuyerCurrencyQuote's product-shape gates. Free trials remain
    # excluded; supported later-charge shapes require the shared ramp.
    def unquotable_purchase?(purchase)
      product = purchase.link
      return true if product.free_trial_enabled?
      if product.is_in_preorder_state? || purchase.is_preorder_authorization? ||
         purchase.is_commission_deposit_purchase? || purchase.is_installment_payment?
        return !self.class.subscriptions_enabled?(product.user)
      end
      return false unless product.is_recurring_billing?

      !self.class.subscriptions_enabled?(product.user)
    end

    # Product-only compatibility for callers that do not have a purchase shape. A product that
    # merely offers installments remains quotable; the selected installment intent is checked on
    # the purchase by #unquotable_purchase?.
    def unquotable_product?(product)
      return true if product.free_trial_enabled?
      return !self.class.subscriptions_enabled?(product.user) if product.is_in_preorder_state? || product.native_type == Link::NATIVE_TYPE_COMMISSION
      return false unless product.is_recurring_billing?

      !self.class.subscriptions_enabled?(product.user)
    end
end
