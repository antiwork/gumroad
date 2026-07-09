# frozen_string_literal: true

# Builds the presentment snapshot for a client-confirmed checkout paying with a
# method-forced local payment method (iDEAL/Bancontact — methods that can only charge
# in one currency, per Checkout::BuyerCurrencyEligibility::FORCED_CURRENCY_PAYMENT_METHODS).
#
# Unlike the card-path Charge::PresentmentOrchestrator — which runs at charge time and
# replays a quote the buyer already locked at checkout — this runs at intent-*prepare*
# time (Order::PreparePaymentIntentService), before the buyer confirms, because the
# deferred PaymentIntent must be created in the forced currency up front: Stripe rejects
# an iDEAL confirmation against a USD intent.
#
# Two amount-derivation cases, decided by the eligibility service:
#   1. Product already priced in the forced currency (direct listed amount): the buyer
#      is charged the listed price as-is — no FX quote is fetched and the quote columns
#      on the presentment rows stay null by design. Tax/shipping components (computed in
#      USD on the purchase) are converted back using the purchase's own stored
#      rate_converted_to_usd, the same rate that produced those USD figures, so no new
#      FX exposure is introduced.
#   2. USD-priced product: a Stripe FX quote is minted (same machinery as the card
#      path's Checkout::BuyerCurrencyQuote) and the canonical USD total converts through
#      it; quote fields are persisted exactly as on the card path.
#
# Returns nil whenever the checkout is ineligible or anything fails, which leaves the
# caller on today's canonical USD behavior. Cleanup of persisted rows when the prepared
# intent later fails/expires is handled by the abandonment step, not here.
class Charge::MethodForcedPresentment
  include CurrencyHelper

  Result = Struct.new(:presentment_total_cents,
                      :presentment_currency,
                      :presentment_gumroad_amount_cents,
                      :stripe_fx_quote_id,
                      :idempotency_key,
                      keyword_init: true)

  # PaymentIntent idempotency key strategy. The card path keys on the Stripe FX quote id
  # (unique per quote, so retries with the same locked quote are idempotent), and the
  # quoted case here does the same. The direct-listed-amount case has no quote to key on,
  # so it keys on the charge's external id + presentment currency instead — both stable
  # for a given prepare attempt, so retrying the same create reuses the same key.
  # Order::PreparePaymentIntentService additionally scopes the final key to the
  # ConfirmationToken (see its comment about test-mode key collisions across CI runs).
  def self.idempotency_key_for(charge:, presentment_currency:, stripe_fx_quote_id: nil)
    if stripe_fx_quote_id.present?
      "buyer-currency-intent-#{charge.external_id}-#{stripe_fx_quote_id}"
    else
      "buyer-currency-intent-#{charge.external_id}-#{presentment_currency}"
    end
  end

  attr_reader :charge, :order, :seller, :merchant_account, :purchases, :amount_cents,
              :gumroad_amount_cents, :payment_method_type, :forced_currency, :params

  # forced_currency: pass explicitly when the buyer picked a method that does not itself
  # force a currency (card/Link) on a Payment Element mounted in a forced currency — the
  # ConfirmationToken inherits the element's currency, so the intent (and therefore this
  # presentment) must be built in it regardless of the method. When nil, the currency is
  # looked up from the payment method's registry entry as before.
  def initialize(charge:, order:, seller:, merchant_account:, purchases:, amount_cents:,
                 gumroad_amount_cents:, payment_method_type:, forced_currency: nil, params: {})
    @charge = charge
    @order = order
    @seller = seller
    @merchant_account = merchant_account
    @purchases = purchases
    @amount_cents = amount_cents
    @gumroad_amount_cents = gumroad_amount_cents
    @payment_method_type = payment_method_type
    @forced_currency = forced_currency
    @params = params || {}
  end

  def perform
    decision = eligibility_decision
    unless decision.eligible?
      Rails.logger.info("Method-forced presentment fallback for charge #{charge.external_id}: #{decision.fallback_reason}")
      return nil
    end

    if decision.direct_listed_amount?
      direct_listed_amount_result(decision)
    else
      quoted_result(decision)
    end
  rescue StandardError => e
    ErrorNotifier.notify(e, context: {
                           charge_id: charge.id,
                           charge_external_id: charge.external_id,
                           merchant_account_id: merchant_account.id,
                           payment_method_type:,
                         })
    Rails.logger.info("Method-forced presentment fallback for charge #{charge.external_id}: #{e.class} #{e.message}")
    nil
  end

  private
    def eligibility_decision
      # chargeable is nil: the client-confirmed flow has no server-side chargeable at
      # prepare time (the browser confirms with a ConfirmationToken), and the
      # method-forced eligibility mode does not consult it.
      Checkout::BuyerCurrencyEligibility.new(
        order:,
        seller:,
        merchant_account:,
        chargeable: nil,
        purchases:,
        params:,
        setup_future_charges: false,
        off_session: false
      ).method_forced_decision(payment_method: payment_method_type, forced_currency:)
    end

    # Case 1: the product is priced in the forced currency, so the buyer pays the listed
    # amount directly — no USD round-trip for the price itself. The purchase's canonical
    # composition is total = displayed price (which already contains any tip, and seller
    # tax when it is included in the price) + excluded seller tax + Gumroad tax +
    # shipping; the last three are stored in USD, so convert each back with the same
    # stored rate that produced them.
    def direct_listed_amount_result(decision)
      purchase = purchases.first
      currency = decision.currency
      rate = purchase.rate_converted_to_usd
      # Without an explicit rate, usd_cents_to_currency silently falls back to the LIVE
      # exchange rate, which would convert tax/shipping with a different rate than the
      # one that produced those USD figures (the whole point of reusing the stored rate).
      # Fail fast instead — the service-level rescue reports it and falls back to the
      # canonical USD path.
      raise "rate_converted_to_usd must be set for method-forced direct-listed-amount presentment (purchase #{purchase.id})" if rate.blank?

      tip_cents = purchase.tip&.value_cents.to_i
      seller_tax_cents = usd_cents_to_currency(currency, purchase.tax_cents.to_i, rate)
      gumroad_tax_cents = usd_cents_to_currency(currency, purchase.gumroad_tax_cents.to_i, rate)
      shipping_cents = usd_cents_to_currency(currency, purchase.shipping_cents.to_i, rate)

      # displayed_price_cents already includes the tip (the buyer's chosen add-on is
      # folded into the display total at purchase-creation time), which is why tip is
      # subtracted below without ever having been added. If that invariant breaks (e.g.
      # a future purchase type stores the tip separately), the subtraction would
      # silently clamp price to 0 — raise early instead so the service-level rescue
      # surfaces it and falls back to the canonical USD path.
      raise "displayed_price_cents must include tip (purchase #{purchase.id}: tip #{tip_cents} > displayed #{purchase.displayed_price_cents})" if tip_cents > purchase.displayed_price_cents

      presentment_total_cents = purchase.displayed_price_cents +
                                (purchase.was_tax_excluded_from_price ? seller_tax_cents : 0) +
                                gumroad_tax_cents + shipping_cents
      # Mirror Charge::PresentmentAllocator's canonical decomposition: price is what
      # remains of the total after the separately-tracked components.
      price_cents = [presentment_total_cents - tip_cents - seller_tax_cents - gumroad_tax_cents - shipping_cents, 0].max
      presentment_gumroad_amount_cents = usd_cents_to_currency(currency, gumroad_amount_cents, rate)

      allocation = Charge::PresentmentAllocator::Allocation.new(
        purchase:,
        presentment_price_cents: price_cents,
        presentment_tip_cents: tip_cents,
        presentment_seller_tax_cents: seller_tax_cents,
        presentment_gumroad_tax_cents: gumroad_tax_cents,
        presentment_shipping_cents: shipping_cents,
        presentment_total_cents:,
        presentment_gumroad_amount_cents:
      )

      Charge::PresentmentOrchestrator.persist!(
        charge:,
        presentment_currency: currency,
        presentment_total_cents:,
        presentment_gumroad_amount_cents:,
        allocations: [allocation]
      )

      Result.new(
        presentment_total_cents:,
        presentment_currency: currency,
        presentment_gumroad_amount_cents:,
        stripe_fx_quote_id: nil,
        idempotency_key: self.class.idempotency_key_for(charge:, presentment_currency: currency)
      )
    end

    # Case 2: USD-priced product — mint a Stripe FX quote (the same underlying machinery
    # Checkout::BuyerCurrencyQuote uses on the card path; that service's entry point is
    # GeoIP-driven so it cannot be reused directly here, where the payment method fixes
    # the currency) and convert the canonical USD totals through it.
    def quoted_result(decision)
      currency = decision.currency
      quote = StripeFxQuote.create(
        to_currency: Currency::USD,
        from_currency: currency,
        stripe_account_id: merchant_account.charge_processor_merchant_id
      )

      presentment_total_cents = presentment_cents_for(amount_cents, quote.fx_rate, currency)
      presentment_gumroad_amount_cents = presentment_cents_for(gumroad_amount_cents, quote.fx_rate, currency)

      allocations = Charge::PresentmentAllocator.new(
        purchases:,
        presentment_total_cents:,
        presentment_gumroad_amount_cents:
      ).allocations

      Charge::PresentmentOrchestrator.persist!(
        charge:,
        presentment_currency: currency,
        presentment_total_cents:,
        presentment_gumroad_amount_cents:,
        allocations:,
        stripe_fx_quote_id: quote.id,
        stripe_fx_quote_expires_at: quote.expires_at,
        fx_rate: quote.fx_rate
      )

      Result.new(
        presentment_total_cents:,
        presentment_currency: currency,
        presentment_gumroad_amount_cents:,
        stripe_fx_quote_id: quote.id,
        idempotency_key: self.class.idempotency_key_for(charge:, presentment_currency: currency, stripe_fx_quote_id: quote.id)
      )
    end

    # Same conversion as Checkout::BuyerCurrencyQuote / Charge::PresentmentOrchestrator:
    # the fx_rate expresses 1 unit of the presentment currency in USD, so divide.
    def presentment_cents_for(canonical_usd_cents, fx_rate, currency)
      raise ArgumentError, "FX rate must be positive" unless fx_rate.positive?

      ((BigDecimal(canonical_usd_cents.to_s) / subunit_to_unit(Currency::USD)) / fx_rate * subunit_to_unit(currency)).round
    end
end
