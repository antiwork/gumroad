# frozen_string_literal: true

class Checkout::BuyerCurrencyEligibility
  include CurrencyHelper

  FEATURE_NAME = :buyer_currency_charging

  Decision = Struct.new(:eligible, :currency, :fallback_reason, keyword_init: true) do
    def eligible?
      eligible
    end
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
    stripe_test_mode? &&
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
    return fallback(:live_mode) unless stripe_test_mode?
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

  private
    def eligible(currency:)
      Decision.new(eligible: true, currency:, fallback_reason: nil)
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
