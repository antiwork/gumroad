# frozen_string_literal: true

# Charges a delayed purchase the fixed buyer-currency amount stored at checkout.
#
# Wired in at Purchase#create_charge_intent, where subscription renewals, installments,
# preorder releases, and commission completions all charge their saved payment method.
#
# Charge::CreateService carries a defensive hook for off-session combined charges. The direct
# Purchase path is load-bearing for the delayed product types above.
#
# What is fixed and what is not (gumroad-private#1322, ruled 2026-07-28):
#
#   * FIXED — the price. Read from the stored fixing, never re-derived at today's rate.
#   * NOT FIXED — tip, tax, and shipping. They are converted at today's rate when present.
#
# A fresh quote is minted per charge even though the price does not move. The quote is what
# makes Stripe settle the intent at a rate we know rather than at whatever rate applies when
# the charge lands, and Stripe's quotes expire in 24 hours, so a stored one could never be
# reused. The stored amount is what the quote CONVERTS, not a substitute for having one.
class Purchase::LaterChargePresentmentService
  Result = Struct.new(:processor_amount_cents,
                      :processor_currency,
                      :processor_gumroad_amount_cents,
                      :stripe_fx_quote_id,
                      keyword_init: true)

  include CurrencyHelper

  attr_reader :charge, :merchant_account, :purchases, :amount_cents, :gumroad_amount_cents, :fallback_reason,
              :required_currency, :required_currency_error_code, :required_currency_error_message

  def initialize(merchant_account:, purchases:, amount_cents:, gumroad_amount_cents:, charge: nil, required_currency: nil,
                 required_currency_error_code: PurchaseErrorCode::UPI_RECURRING_AUTHORIZATION_REQUIRED,
                 required_currency_error_message: StripeChargeProcessor::UPI_PAYMENT_METHOD_UPDATE_MESSAGE)
    @charge = charge
    @merchant_account = merchant_account
    @purchases = purchases
    @amount_cents = amount_cents
    @gumroad_amount_cents = gumroad_amount_cents
    @required_currency = required_currency&.to_s&.downcase
    @required_currency_error_code = required_currency_error_code
    @required_currency_error_message = required_currency_error_message
  end

  # Returns a Result in the stored currency, or nil to leave the caller charging canonical USD.
  #
  # Ordinary cards fall back to canonical USD; a required-currency rail either re-fixes a
  # direct-listed renewal or requires the buyer to update their payment method.
  def perform
    presentment = stored_presentment
    return fallback(:no_stored_presentment) if presentment.blank?

    purchase = purchases.first
    currency = presentment.presentment_currency
    return fallback(:required_currency_mismatch) if required_currency.present? && currency != required_currency
    return fallback(:unsupported_currency) unless StripeChargeProcessor.charge_minor_units_compatible?(currency)
    return fallback(:unsupported_charge_model) unless Checkout::BuyerCurrencyEligibility.supported_merchant_account?(merchant_account)
    return fallback(:settlement_currency_mismatch) unless Checkout::BuyerCurrencyEligibility.usd_settling_merchant_account?(merchant_account, presentment_currency: currency)

    canonical_price_cents = LaterChargePresentment.canonical_price_cents_for(purchase)
    if presentment.canonical_price_cents != canonical_price_cents
      presentment = refix_required_currency_presentment(presentment, purchase, canonical_price_cents)
      return fallback(:stale_fixing) if presentment.blank? || presentment.canonical_price_cents != canonical_price_cents
    end

    quote = mint_quote(currency)
    return fallback(:quote_unavailable, transient: true) if quote.blank?

    # The stored price is charged as-is. Tax and shipping ride on today's rate.
    fixed_price_cents = presentment.presentment_price_cents

    variable_canonical_cents = variable_component_canonical_cents(purchase)
    variable_presentment_cents = presentment_cents_for(variable_canonical_cents, quote.fx_rate, currency)
    presentment_total_cents = fixed_price_cents + variable_presentment_cents
    return fallback(:non_positive_total) unless presentment_total_cents.positive?

    # Gumroad's share converts at today's rate. Because the buyer's price stays fixed, the
    # resulting FX drift remains in the seller's proceeds.
    presentment_gumroad_amount_cents =
      presentment_cents_for(gumroad_amount_cents, quote.fx_rate, currency).clamp(0, presentment_total_cents)

    allocation = Charge::PresentmentAllocator::Allocation.new(
      purchase:,
      presentment_price_cents: fixed_price_cents,
      presentment_tip_cents: presentment_cents_for(purchase.tip&.value_usd_cents.to_i, quote.fx_rate, currency),
      presentment_seller_tax_cents: presentment_cents_for(purchase.tax_cents.to_i, quote.fx_rate, currency),
      presentment_gumroad_tax_cents: presentment_cents_for(purchase.gumroad_tax_cents.to_i, quote.fx_rate, currency),
      presentment_shipping_cents: presentment_cents_for(purchase.shipping_cents.to_i, quote.fx_rate, currency),
      presentment_total_cents:,
      presentment_gumroad_amount_cents:
    )
    # The components are converted independently and the price is fixed, so their sum can
    # miss the total by a cent. PurchasePresentment validates that they sum exactly, so
    # settle the difference on the price — the one component this lane is authoritative
    # about — rather than on a tax figure that has to stay truthful.
    reconcile_price_component!(allocation)

    Charge::PresentmentOrchestrator.persist!(
      charge:,
      presentment_currency: currency,
      presentment_total_cents:,
      presentment_gumroad_amount_cents:,
      allocations: [allocation],
      stripe_fx_quote_id: quote.id,
      stripe_fx_quote_expires_at: quote.expires_at,
      fx_rate: quote.fx_rate,
      rounding_delta_cents: 0
    )

    Result.new(
      processor_amount_cents: presentment_total_cents,
      processor_currency: currency,
      processor_gumroad_amount_cents: presentment_gumroad_amount_cents,
      stripe_fx_quote_id: quote.id
    )
  rescue ChargeProcessorCardError, ChargeProcessorUnavailableError
    raise
  rescue StandardError => e
    ErrorNotifier.notify(e, context: { charge_id: charge&.id, purchase_id: purchases.first&.id })
    fallback(:"#{e.class}", transient: true)
  end

  private
    # These delayed paths each charge one purchase. Anything else is a shape this service has
    # not reasoned about and must not guess at.
    def stored_presentment
      return if purchases.blank? || !purchases.one?

      later_charge_owner(purchases.first)&.current_later_charge_presentment
    end

    def later_charge_owner(purchase)
      if purchase.subscription.present?
        purchase.subscription unless purchase.is_original_subscription_purchase?
      elsif purchase.preorder.present?
        purchase.preorder unless purchase.is_preorder_authorization?
      elsif purchase.is_commission_completion_purchase?
        purchase.commission
      end
    end

    def refix_required_currency_presentment(presentment, purchase, canonical_price_cents)
      return if required_currency.blank? || presentment.presentment_currency != required_currency
      return unless purchase.link.price_currency_type.to_s.downcase == required_currency
      return unless purchase.displayed_price_currency_type.to_s.downcase == required_currency

      presentment_price_cents = purchase.displayed_price_cents.to_i
      currency_units_per_usd = purchase.rate_converted_to_usd&.to_d
      return unless canonical_price_cents.positive? && presentment_price_cents.positive? && currency_units_per_usd&.positive?

      owner = later_charge_owner(purchase)
      return if owner.blank?

      owner.with_lock do
        current = owner.current_later_charge_presentment
        if current&.presentment_currency == required_currency && current.canonical_price_cents == canonical_price_cents
          current
        elsif current&.presentment_currency != required_currency
          nil
        else
          owner.later_charge_presentments.create!(
            processor: StripeChargeProcessor.charge_processor_id,
            presentment_currency: required_currency,
            presentment_price_cents:,
            canonical_price_cents:,
            signup_currency_units_per_usd: currency_units_per_usd,
            effective_from: Time.current
          )
        end
      end
    end

    # Everything except the fixed price converts at today's rate.
    def variable_component_canonical_cents(purchase)
      purchase.tip&.value_usd_cents.to_i + purchase.tax_cents.to_i +
        purchase.gumroad_tax_cents.to_i + purchase.shipping_cents.to_i
    end

    def reconcile_price_component!(allocation)
      components = [
        allocation.presentment_price_cents,
        allocation.presentment_tip_cents,
        allocation.presentment_seller_tax_cents,
        allocation.presentment_gumroad_tax_cents,
        allocation.presentment_shipping_cents,
      ]
      difference = allocation.presentment_total_cents - components.sum
      return if difference.zero?

      allocation.presentment_price_cents += difference
    end

    # Minted on the account that will create the intent, mirroring the card and
    # method-forced lanes on this branch.
    #
    # NOTE for whoever rebases this onto #6477 (destination-charge quoting): that PR moves
    # quote minting onto the platform account and declares the transfer destination, because
    # Stripe rejects an intent whose `transfer_data.destination` does not match the quote's
    # declared destination. When these two branches meet, this call must adopt the same
    # resolver (Checkout::BuyerCurrencyEligibility.fx_quote_merchant_account /
    # .fx_quote_destination_account_id) or destination charges will fail the pairing
    # check and fall back to USD.
    def mint_quote(currency)
      StripeFxQuote.create(
        to_currency: Currency::USD,
        from_currency: currency,
        stripe_account_id: merchant_account.charge_processor_merchant_id
      )
    end

    def presentment_cents_for(canonical_usd_cents, fx_rate, currency)
      return 0 if canonical_usd_cents.to_i.zero?
      raise ArgumentError, "FX rate must be positive" unless fx_rate.positive?

      ((BigDecimal(canonical_usd_cents.to_s) / subunit_to_unit(Currency::USD)) / fx_rate * subunit_to_unit(currency)).round
    end

    def fallback(reason, transient: false)
      @fallback_reason = reason
      Rails.logger.info("Later-charge presentment fallback for #{charge.present? ? "charge #{charge.external_id}" : "purchase #{purchases.first&.id}"}: #{reason}")
      if required_currency.present?
        notification = transient ? "Required-currency renewal deferred before processor submit" : "Required-currency renewal rejected before processor submit"
        ErrorNotifier.notify(
          notification,
          reason:,
          required_currency:,
          purchase_id: purchases.first&.id,
          charge_id: charge&.id
        )
        if transient
          raise ChargeProcessorUnavailableError, "The required-currency quote is temporarily unavailable"
        end

        raise ChargeProcessorCardError.new(
          required_currency_error_code,
          required_currency_error_message
        )
      end

      nil
    end
end
