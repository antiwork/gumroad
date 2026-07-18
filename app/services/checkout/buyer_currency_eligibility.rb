# frozen_string_literal: true

class Checkout::BuyerCurrencyEligibility
  include CurrencyHelper

  FEATURE_NAME = :buyer_currency_charging

  # Some local payment methods only work in a single currency: iDEAL and Bancontact
  # charges must be made in euros, full stop. When a checkout wants one of these
  # methods, the payment method itself decides the presentment currency — there is
  # nothing to detect from the buyer's location. This registry maps each such
  # payment method (Stripe payment method type string) to the currency it forces.
  # To support a new forced-currency method, add it here.
  FORCED_CURRENCY_PAYMENT_METHODS = {
    "ideal" => Currency::EUR,
    "bancontact" => Currency::EUR,
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

  attr_reader :order, :seller, :merchant_account, :chargeable, :purchases, :params, :setup_future_charges, :off_session

  def self.seller_enabled?(seller)
    seller.present? &&
      Feature.active?(FEATURE_NAME, seller) &&
      Feature.active?(:buyer_local_currency, seller) &&
      !seller.disable_buyer_local_currency?
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

  def self.usd_settling_merchant_account?(merchant_account)
    merchant_account.currency.blank? || merchant_account.currency.to_s.downcase == Currency::USD
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
    return fallback(:unsupported_settlement_currency) unless usd_settling_merchant_account?
    return fallback(:wallet_payment_request) if wallet_type.present?
    return fallback(:future_charge_setup) if setup_future_charges
    return fallback(:off_session) if off_session
    return fallback(:multi_item_checkout) unless purchases.one?
    return fallback(:missing_stripe_chargeable) if chargeable&.get_chargeable_for(StripeChargeProcessor.charge_processor_id).blank?

    purchase = purchases.first
    return fallback(:unsupported_product_type) if unsupported_product_type?(purchase)
    return fallback(:unsupported_product_currency) unless purchase.link.price_currency_type.to_s.downcase == Currency::USD

    buyer_currency = buyer_currency_for_ip(purchase.ip_address)
    return fallback(:missing_buyer_currency) if buyer_currency.blank?
    return fallback(:canonical_buyer_currency) if buyer_currency == Currency::USD
    return fallback(:unsupported_buyer_currency) unless StripeChargeProcessor.charge_minor_units_compatible?(buyer_currency)

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
  # only mounts a forced-currency element for a product priced in that currency
  # (method_forced_qa_shape?), so these checkouts land in the direct-listed-amount case.
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
    return fallback(:live_mode) unless stripe_test_mode?
    return fallback(:unsupported_processor) unless merchant_account&.stripe_charge_processor?
    return fallback(:unsupported_charge_model) unless supported_charge_model?
    # Presentment currency and settlement currency are separate questions: even
    # when the product is already priced in the forced currency (say EUR), the
    # seller's merchant account still receives the money, and today the pipeline
    # only knows how to settle accounts that hold USD. So this check applies to
    # both the USD-priced and the forced-currency-priced product cases.
    return fallback(:unsupported_settlement_currency) unless usd_settling_merchant_account?
    return fallback(:future_charge_setup) if setup_future_charges
    return fallback(:off_session) if off_session
    return fallback(:multi_item_checkout) unless purchases.one?

    purchase = purchases.first
    return fallback(:unsupported_product_type) if unsupported_product_type?(purchase)

    product_currency = purchase.link.price_currency_type.to_s.downcase
    # Two supported pricing cases:
    #   1. Product priced in the forced currency itself (e.g. an EUR-priced
    #      product paid with iDEAL) — charge the listed amount directly, no FX
    #      quote needed.
    #   2. Product priced in USD — the charge path converts through an FX quote.
    # Any other product currency cannot be presented in the forced currency.
    priced_in_forced_currency = product_currency == forced_currency
    unless priced_in_forced_currency || product_currency == Currency::USD
      return fallback(:unsupported_product_currency)
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

    def usd_settling_merchant_account?
      self.class.usd_settling_merchant_account?(merchant_account)
    end

    def supported_charge_model?
      self.class.supported_merchant_account?(merchant_account)
    end

    def wallet_type
      params[:wallet_type]
    end

    # Commission deposits and installment payments charge less than the locked cart total
    # (issue #5419 excludes both from Phase 1), so they must fall back even when a valid
    # quote token reaches the charge path.
    def unsupported_product_type?(purchase)
      purchase.is_commission_deposit_purchase? ||
        purchase.is_installment_payment? ||
        purchase.link.native_type == Link::NATIVE_TYPE_COMMISSION
    end
end
