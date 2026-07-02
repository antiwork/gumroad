# frozen_string_literal: true

class Checkout::BuyerCurrencyQuote
  include CurrencyHelper

  InvalidToken = Class.new(StandardError)

  Result = Struct.new(:token,
                      :currency,
                      :canonical_total_cents,
                      :presentment_total_cents,
                      :fx_rate,
                      :stripe_fx_quote_id,
                      :stripe_fx_quote_expires_at,
                      keyword_init: true) do
    def id
      stripe_fx_quote_id
    end

    def expires_at
      stripe_fx_quote_expires_at
    end
  end

  TOKEN_PURPOSE = :buyer_currency_quote

  def self.create(products:, canonical_total_cents:, ip:)
    new(products:, canonical_total_cents:, ip:).create
  end

  def self.verify!(token:, seller:, merchant_account:, currency:, canonical_total_cents:)
    payload = verifier.verify(token)

    raise InvalidToken, "expired buyer currency quote" if Time.zone.parse(payload.fetch("stripe_fx_quote_expires_at")) <= Time.current
    raise InvalidToken, "seller mismatch" unless payload.fetch("seller_id") == seller.id
    raise InvalidToken, "merchant account mismatch" unless payload.fetch("merchant_account_id") == merchant_account.id
    raise InvalidToken, "currency mismatch" unless payload.fetch("currency") == currency.to_s
    raise InvalidToken, "total mismatch" unless payload.fetch("canonical_total_cents") == canonical_total_cents.to_i
    raise InvalidToken, "stripe account mismatch" unless payload.fetch("stripe_account_id") == merchant_account.charge_processor_merchant_id

    Result.new(
      token:,
      currency: payload.fetch("currency"),
      canonical_total_cents: payload.fetch("canonical_total_cents"),
      presentment_total_cents: payload.fetch("presentment_total_cents"),
      fx_rate: BigDecimal(payload.fetch("fx_rate")),
      stripe_fx_quote_id: payload.fetch("stripe_fx_quote_id"),
      stripe_fx_quote_expires_at: Time.zone.parse(payload.fetch("stripe_fx_quote_expires_at"))
    )
  rescue ActiveSupport::MessageVerifier::InvalidSignature, KeyError, TypeError, ArgumentError => e
    raise InvalidToken, e.message
  end

  def self.verifier
    Rails.application.message_verifier(TOKEN_PURPOSE)
  end
  private_class_method :verifier

  attr_reader :products, :canonical_total_cents, :ip

  def initialize(products:, canonical_total_cents:, ip:)
    @products = products
    @canonical_total_cents = canonical_total_cents.to_i
    @ip = ip
  end

  def create
    return if canonical_total_cents <= 0
    return unless products.one?

    product = products.first
    seller = product.user
    return unless Checkout::BuyerCurrencyEligibility.seller_enabled?(seller)
    return unless Checkout::BuyerCurrencyEligibility.stripe_test_mode?
    return unless product.price_currency_type.to_s.downcase == Currency::USD
    return if product.is_in_preorder_state? || product.is_recurring_billing? || product.free_trial_enabled?
    # Commissions charge only a deposit now and installment plans charge only the first
    # payment, so a quote locked against the full cart total can never match the charged
    # amount; issue #5419 excludes both from Phase 1. Installment intent is not visible at
    # quote time, so any product offering an installment plan falls back.
    return if product.native_type == Link::NATIVE_TYPE_COMMISSION
    return if product.installment_plan.present?

    merchant_account = seller.merchant_account(StripeChargeProcessor.charge_processor_id) ||
                       MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id)
    return unless merchant_account&.stripe_charge_processor?
    return unless Checkout::BuyerCurrencyEligibility.supported_merchant_account?(merchant_account)
    return unless Checkout::BuyerCurrencyEligibility.usd_settling_merchant_account?(merchant_account)

    buyer_currency = buyer_currency_for_ip(ip)
    return if buyer_currency.blank? || buyer_currency == Currency::USD
    return unless StripeChargeProcessor.charge_minor_units_compatible?(buyer_currency)

    quote = StripeFxQuote.create(
      to_currency: Currency::USD,
      from_currency: buyer_currency,
      stripe_account_id: merchant_account.charge_processor_merchant_id
    )
    presentment_total_cents = presentment_cents_for(canonical_total_cents, quote.fx_rate, buyer_currency)

    Result.new(
      token: signed_token(
        seller:,
        merchant_account:,
        buyer_currency:,
        quote:,
        presentment_total_cents:
      ),
      currency: buyer_currency,
      canonical_total_cents:,
      presentment_total_cents:,
      fx_rate: quote.fx_rate,
      stripe_fx_quote_id: quote.id,
      stripe_fx_quote_expires_at: quote.expires_at
    )
  rescue StandardError => e
    ErrorNotifier.notify(e, context: {
                           product_ids: products.map(&:id),
                           canonical_total_cents:,
                           ip:
                         })
    Rails.logger.info("Buyer currency quote fallback: #{e.class} #{e.message}")
    nil
  end

  private
    def signed_token(seller:, merchant_account:, buyer_currency:, quote:, presentment_total_cents:)
      self.class.send(:verifier).generate(
        {
          seller_id: seller.id,
          merchant_account_id: merchant_account.id,
          stripe_account_id: merchant_account.charge_processor_merchant_id,
          currency: buyer_currency,
          canonical_total_cents:,
          presentment_total_cents:,
          stripe_fx_quote_id: quote.id,
          stripe_fx_quote_expires_at: quote.expires_at.iso8601,
          fx_rate: quote.fx_rate.to_s("F"),
        }
      )
    end

    def presentment_cents_for(canonical_usd_cents, fx_rate, currency)
      raise ArgumentError, "FX rate must be positive" unless fx_rate.positive?

      ((BigDecimal(canonical_usd_cents.to_s) / subunit_to_unit(Currency::USD)) / fx_rate * subunit_to_unit(currency)).round
    end
end
