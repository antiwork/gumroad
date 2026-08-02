# frozen_string_literal: true

# Prices a checkout whose products are already listed in the currency we are about to
# charge, so there is no FX quote anywhere in the flow: the buyer pays the listed price
# as-is. Used by two lanes that reach the same situation from different directions —
# a EUR-priced product paid with iDEAL (Charge::MethodForcedPresentment) and a
# CAD-priced product bought by a Canadian on a card (Charge::CreateService).
#
# Tax, shipping and the Gumroad share are computed in USD on the purchase, so they are
# converted back with that purchase's own stored rate_converted_to_usd — the same rate
# that produced those USD figures. Nothing here consults a live rate, which is what
# makes this lane free of new FX exposure.
class Charge::DirectListedAmountPresentment
  include CurrencyHelper

  Result = Struct.new(:presentment_total_cents,
                      :presentment_gumroad_amount_cents,
                      :allocations,
                      keyword_init: true)

  attr_reader :purchases, :currency, :gumroad_amount_cents

  def initialize(purchases:, currency:, gumroad_amount_cents:)
    @purchases = purchases
    @currency = currency
    @gumroad_amount_cents = gumroad_amount_cents
  end

  def perform
    allocations = purchases.map { allocation_for(_1) }

    Result.new(
      presentment_total_cents: allocations.sum(&:presentment_total_cents),
      presentment_gumroad_amount_cents: allocations.sum(&:presentment_gumroad_amount_cents),
      allocations:
    )
  end

  private
    def allocation_for(purchase)
      rate = purchase.rate_converted_to_usd
      # Without an explicit rate, usd_cents_to_currency silently falls back to the LIVE
      # exchange rate, which would convert tax/shipping with a different rate than the
      # one that produced those USD figures. Fail fast instead — callers rescue this and
      # fall back to the canonical USD path.
      raise "rate_converted_to_usd must be set for direct-listed-amount presentment (purchase #{purchase.id})" if rate.blank?

      tip_cents = purchase.tip&.value_cents.to_i
      seller_tax_cents = usd_cents_to_currency(currency, purchase.tax_cents.to_i, rate)
      gumroad_tax_cents = usd_cents_to_currency(currency, purchase.gumroad_tax_cents.to_i, rate)
      shipping_cents = usd_cents_to_currency(currency, purchase.shipping_cents.to_i, rate)

      # displayed_price_cents already includes the tip, which is why tip is subtracted
      # below without ever having been added. If that invariant breaks, the subtraction
      # would silently clamp price to 0 — raise instead so the caller falls back.
      raise "displayed_price_cents must include tip (purchase #{purchase.id}: tip #{tip_cents} > displayed #{purchase.displayed_price_cents})" if tip_cents > purchase.displayed_price_cents

      presentment_total_cents = purchase.displayed_price_cents +
                                (purchase.was_tax_excluded_from_price ? seller_tax_cents : 0) +
                                gumroad_tax_cents + shipping_cents
      # Mirror Charge::PresentmentAllocator's canonical decomposition: price is what
      # remains of the total after the separately-tracked components.
      price_cents = [presentment_total_cents - tip_cents - seller_tax_cents - gumroad_tax_cents - shipping_cents, 0].max
      # The Gumroad share converts independently of the listed-price-based total, so
      # adverse double-rounding could put it a cent above the purchase total and fail
      # PurchasePresentment's validation. Cap it at the total.
      presentment_gumroad_amount_cents = [usd_cents_to_currency(currency, canonical_gumroad_amount_cents_for(purchase), rate), presentment_total_cents].min

      Charge::PresentmentAllocator::Allocation.new(
        purchase:,
        presentment_price_cents: price_cents,
        presentment_tip_cents: tip_cents,
        presentment_seller_tax_cents: seller_tax_cents,
        presentment_gumroad_tax_cents: gumroad_tax_cents,
        presentment_shipping_cents: shipping_cents,
        presentment_total_cents:,
        presentment_gumroad_amount_cents:
      )
    end

    def canonical_gumroad_amount_cents_for(purchase)
      return gumroad_amount_cents if purchases.one?

      purchase.total_transaction_amount_for_gumroad_cents
    end
end
