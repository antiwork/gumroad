# frozen_string_literal: true

# Charges a membership renewal the fixed buyer-currency amount stored at signup.
#
# Wired in at Purchase#create_charge_intent (purchase.rb), which is where renewals actually
# charge: RecurringChargeWorker -> Subscription#charge! -> #process_purchase! -> Purchase#process!
# -> #create_charge_intent -> ChargeProcessor. Renewals never pass through Charge::CreateService,
# whose only caller is Order::ChargeService (checkout) — an earlier version of this service hooked
# there and was unreachable dead code as a result.
#
# The lane this fills. A card checkout presents in the buyer's currency by
# verifying a signed quote the buyer confirmed in the browser
# (Charge::PresentmentOrchestrator). A renewal has no browser and no quote token, so there is
# nothing for the buyer to confirm and nothing to verify against.
#
# What is fixed and what is not (gumroad-private#1322, ruled 2026-07-28):
#
#   * FIXED — the PRICE. Read from the stored fixing, never re-derived from a current
#     rate. A EUR 9.99 member pays EUR 9.99 every month, exactly as a USD member pays $10.
#     Gumroad absorbs the FX drift; #usd_drift_cents makes it attributable per subscription
#     rather than emergent in the margin.
#   * NOT FIXED — tax and shipping. Both are recomputed per renewal (VAT rates change, the
#     member can move), so they are converted at TODAY's rate via a fresh quote. Freezing
#     them would charge stale tax, which is a compliance problem, not a kindness.
#
# A FRESH quote is minted per renewal even though the price does not move. The quote is what
# makes Stripe settle the intent at a rate we know rather than at whatever rate applies when
# the charge lands, and Stripe's quotes expire in 24 hours, so a stored one could never be
# reused. The stored amount is what the quote CONVERTS, not a substitute for having one.
class Subscription::PresentmentRenewal
  Result = Struct.new(:processor_amount_cents,
                      :processor_currency,
                      :processor_gumroad_amount_cents,
                      :stripe_fx_quote_id,
                      keyword_init: true)

  include CurrencyHelper

  attr_reader :charge, :merchant_account, :purchases, :amount_cents, :gumroad_amount_cents, :fallback_reason

  def initialize(merchant_account:, purchases:, amount_cents:, gumroad_amount_cents:, charge: nil)
    @charge = charge
    @merchant_account = merchant_account
    @purchases = purchases
    @amount_cents = amount_cents
    @gumroad_amount_cents = gumroad_amount_cents
  end

  # Returns a Result to present the renewal in the member's currency, or nil to leave the
  # caller charging canonical USD.
  #
  # Every refusal here is a FALLBACK, not a failure. This differs deliberately from the card
  # lane, which fails closed: there, a buyer is watching a confirmed local total and charging
  # anything else would break the amount they agreed to. Here there is no browser and no
  # confirmed total for THIS charge — the alternative is the canonical USD charge that every
  # renewal made before this feature existed. Failing the renewal outright would dun a paying
  # member and risk cancelling a live subscription over an FX-quote hiccup, which is strictly
  # worse than billing them the USD equivalent for one period.
  def perform
    presentment = stored_presentment
    return fallback(:no_stored_presentment) if presentment.blank?

    purchase = purchases.first
    currency = presentment.presentment_currency
    return fallback(:unsupported_currency) unless StripeChargeProcessor.charge_minor_units_compatible?(currency)
    return fallback(:settlement_currency_mismatch) unless Checkout::BuyerCurrencyEligibility.usd_settling_merchant_account?(merchant_account, presentment_currency: currency)

    quote = mint_quote(currency)
    return fallback(:quote_unavailable) if quote.blank?

    # The stored price is charged as-is. Tax and shipping ride on today's rate.
    fixed_price_cents = presentment.presentment_price_cents

    # STALENESS GATE. The fixed amount is only valid while the plan it was agreed against has not
    # moved. A subscription's canonical price legitimately changes mid-life — a limited-duration
    # discount runs out (see Purchase#mandate_maximum_amount_cents, which exists because renewals
    # bill the undiscounted price), Subscription#update_current_plan! applies an upgrade,
    # downgrade or quantity change, a SubscriptionPlanChange lands. The fixing cannot follow those
    # on its own, so billing it anyway would silently under-charge (Gumroad pays the seller money
    # it never collected) or over-charge (billing more than the member agreed, which is a consent
    # and card-network problem, not just an accounting one).
    #
    # Falling back to canonical dollars is the safe answer: the member is billed exactly what the
    # current plan says, which is what they would have been billed before this feature existed.
    # Re-fixing the amount at the new price belongs to the plan-change paths and is not built yet.
    #
    # Compared on the plan's own price with tax, tip and shipping taken back out
    # (LaterChargePresentment.canonical_price_cents_for), which is the same figure the signup
    # stored. Comparing raw price_cents instead would trip on a member moving house or a VAT
    # change, neither of which moves the plan price the fixing is about.
    return fallback(:stale_fixing) unless presentment.canonical_price_cents == LaterChargePresentment.canonical_price_cents_for(purchase)

    variable_canonical_cents = variable_component_canonical_cents(purchase)
    variable_presentment_cents = presentment_cents_for(variable_canonical_cents, quote.fx_rate, currency)
    presentment_total_cents = fixed_price_cents + variable_presentment_cents
    return fallback(:non_positive_total) unless presentment_total_cents.positive?

    # Gumroad's share converts at today's rate like any other renewal: the fee is a
    # percentage of the canonical USD amount, and holding it fixed would let Gumroad's cut
    # drift away from the fee schedule the seller agreed to.
    presentment_gumroad_amount_cents =
      presentment_cents_for(gumroad_amount_cents, quote.fx_rate, currency).clamp(0, presentment_total_cents)

    allocation = Charge::PresentmentAllocator::Allocation.new(
      purchase:,
      presentment_price_cents: fixed_price_cents,
      presentment_tip_cents: 0,
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

    # Snapshot rows hang off a Charge, which only exists for a checkout combined charge. A
    # standalone renewal (RecurringChargeWorker -> Purchase#create_charge_intent) has no Charge:
    # the amounts are returned to the caller and recorded on the purchase once the charge
    # succeeds, so there is nothing to persist here and nothing to roll back if Stripe declines.
    if charge.present?
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
    end

    Result.new(
      processor_amount_cents: presentment_total_cents,
      processor_currency: currency,
      processor_gumroad_amount_cents: presentment_gumroad_amount_cents,
      stripe_fx_quote_id: quote.id
    )
  rescue StandardError => e
    # An unexpected failure must not cost the seller a renewal, so notify and let the caller
    # charge canonical USD.
    ErrorNotifier.notify(e, context: { charge_id: charge&.id, purchase_id: purchases.first&.id })
    fallback(:"#{e.class}")
  end

  private
    # Only a single-purchase renewal is in this lane. A renewal charge carries exactly one
    # purchase (RecurringChargeWorker charges one subscription), so anything else is a shape
    # this service has not reasoned about and must not guess at.
    #
    # Reads current_later_charge_presentment, not the whole collection: fixings are immutable
    # and effective-dated, so the newest one that has taken effect is the amount to charge. A
    # future-dated fixing (a scheduled price change) deliberately does not apply yet.
    def stored_presentment
      return if purchases.blank? || !purchases.one?

      purchase = purchases.first
      return if purchase.subscription.blank?
      return if purchase.is_original_subscription_purchase?

      purchase.subscription.current_later_charge_presentment
    end

    # Everything on the renewal except the price: tax and shipping, which are recomputed each
    # period and therefore convert at today's rate.
    def variable_component_canonical_cents(purchase)
      purchase.tax_cents.to_i + purchase.gumroad_tax_cents.to_i + purchase.shipping_cents.to_i
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
    # .fx_quote_destination_account_id) or destination-charge renewals will fail the pairing
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

    def fallback(reason)
      @fallback_reason = reason
      Rails.logger.info("Subscription renewal presentment fallback for #{charge.present? ? "charge #{charge.external_id}" : "purchase #{purchases.first&.id}"}: #{reason}")
      nil
    end
end
