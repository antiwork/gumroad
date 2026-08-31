# frozen_string_literal: true

# Coordinates the buyer-presentment charge setup for the PR-1 test-mode path.
#
# Charge::CreateService verifies the signed locked quote, then this orchestrator
# snapshots the buyer-facing presentment amounts on the charge and purchases and
# returns processor arguments for the PaymentIntent. Persisting before processor
# confirmation lets receipts and accounting read a single stored quote, but it
# also means post-money-movement exceptions need explicit reconciliation in the
# later refund/dispute work. For this PR, Charge::CreateService clears snapshots
# only when the processor path cleanly falls back before a charge intent exists.
class Charge::PresentmentOrchestrator
  include CurrencyHelper

  Result = Struct.new(:processor_amount_cents,
                      :processor_currency,
                      :processor_gumroad_amount_cents,
                      :stripe_fx_quote_id,
                      keyword_init: true)

  attr_reader :charge, :merchant_account, :purchases, :amount_cents, :gumroad_amount_cents, :eligibility_decision, :locked_quote

  # Set when the orchestrator declines to charge for a reason that is expected rather than
  # a defect (see #rounding_absorbable?), so Charge::CreateService can say why it failed
  # closed instead of reporting a generic orchestration failure.
  attr_reader :fallback_reason

  def initialize(charge:, merchant_account:, purchases:, amount_cents:, gumroad_amount_cents:, eligibility_decision:, locked_quote:)
    @charge = charge
    @merchant_account = merchant_account
    @purchases = purchases
    @amount_cents = amount_cents
    @gumroad_amount_cents = gumroad_amount_cents
    @eligibility_decision = eligibility_decision
    @locked_quote = locked_quote
  end

  # Shared presentment persistence, also used by the client-confirm intent-prepare paths.
  # Takes precomputed per-purchase allocations so callers control the component split:
  # the quote-backed path splits proportionally via Charge::PresentmentAllocator, while direct-listed
  # paths supply exact components (the tip the buyer picked in the product's own currency
  # must not be re-derived by proportional rounding). Quote fields are nullable because
  # a direct-listed-amount presentment has no FX quote by design.
  #
  # WHICH PURCHASES GET A PRESENTMENT ROW: exactly the purchases on the charge, which is
  # to say exactly the rows the buyer actually paid for. Two kinds of 0-cent companion
  # row exist elsewhere in a checkout and deliberately do NOT get one:
  #
  #   * the giftee purchase, built inside Purchase::CreateService#create_giftee_purchase
  #     and never appended to the order, so it never reaches a charge; and
  #   * bundle child purchases, created by Purchase::CreateBundleProductPurchaseService
  #     after the parent purchase succeeds, at 0 cents.
  #
  # Both exist to grant access, not to move money — the buyer-facing price lives on the
  # gifter or bundle-parent row. Giving them presentment rows would add zero-weight lines
  # to the allocation and show the buyer per-item buyer-currency amounts for items that
  # were never separately charged. spec/services/order/charge_service_spec.rb pins this
  # for both single-item and multi-item carts.
  def self.persist!(charge: nil, presentment_currency:, presentment_total_cents:, presentment_gumroad_amount_cents:,
                    allocations:, stripe_fx_quote_id: nil, stripe_fx_quote_expires_at: nil, fx_rate: nil,
                    rounding_delta_cents: 0)
    ActiveRecord::Base.transaction do
      allocations.each { _1.purchase.purchase_presentment&.destroy! }
      charge&.charge_presentment&.destroy!

      charge_presentment = charge&.create_charge_presentment!(
        processor: StripeChargeProcessor.charge_processor_id,
        presentment_currency:,
        presentment_total_cents:,
        presentment_gumroad_amount_cents:,
        stripe_fx_quote_id:,
        stripe_fx_quote_expires_at:,
        fx_rate:,
        rounding_delta_cents:
      )

      allocations.each do |allocation|
        allocation.purchase.create_purchase_presentment!(
          charge_presentment:,
          processor: StripeChargeProcessor.charge_processor_id,
          presentment_currency:,
          presentment_price_cents: allocation.presentment_price_cents,
          presentment_tip_cents: allocation.presentment_tip_cents,
          presentment_seller_tax_cents: allocation.presentment_seller_tax_cents,
          presentment_gumroad_tax_cents: allocation.presentment_gumroad_tax_cents,
          presentment_shipping_cents: allocation.presentment_shipping_cents,
          presentment_total_cents: allocation.presentment_total_cents,
          presentment_gumroad_amount_cents: allocation.presentment_gumroad_amount_cents
        )
      end

      charge_presentment
    end
  end

  def perform
    return unless eligibility_decision.eligible?

    # The buyer must be charged exactly the verified locked total they last saw; this
    # orchestrator never mints a fresh quote of its own.
    presentment_total_cents = locked_quote.presentment_total_cents
    rounding_delta_cents = locked_quote.rounding_delta_cents.to_i
    # A round-down was capped at quote time against the fee Gumroad expected to collect,
    # but that expectation can go stale between the quote and the charge (see
    # #rounding_absorbable?). Re-check it here, where the fee is already computed, and
    # refuse the charge rather than fund the reduction out of the seller's proceeds.
    return unless rounding_absorbable?(rounding_delta_cents)

    # Gumroad absorbs the whole rounding difference: the seller's proceeds are the
    # converted canonical amount either way, so a total rounded UP adds to Gumroad's
    # share and a total rounded DOWN comes out of it. The check above establishes that
    # Gumroad's converted share covers a round-down, so this stays non-negative; clamp
    # to the total as well so a pathological cart can never ask Stripe for a fee above
    # the payment (which Stripe rejects, and which would degrade the charge to USD).
    presentment_gumroad_amount_cents = (
      presentment_cents_for(gumroad_amount_cents, locked_quote.fx_rate) + rounding_delta_cents
    ).clamp(0, presentment_total_cents)

    # The allocator derives every component from the EXACT converted total and then carries
    # the price-ending difference on the non-tax components only, so the persisted tax rows
    # (and the receipt built from them) show the true converted tax rather than a share of a
    # cosmetic adjustment. The exact total is recoverable from the signed quote: the locked
    # total is the exact one plus the difference.
    #
    # If the allocator raises (a difference with no non-tax component to carry it), the
    # rescue below returns nil and Charge::CreateService fails the charge closed — it does
    # NOT quietly charge canonical USD, because the buyer confirmed the rounded total and
    # charging anything else would break the invariant this feature rests on. Nothing is
    # persisted either way: the raise happens before the transactional #persist!.
    allocations = Charge::PresentmentAllocator.new(
      purchases:,
      presentment_total_cents: presentment_total_cents - rounding_delta_cents,
      presentment_gumroad_amount_cents:,
      rounding_delta_cents:,
      presentment_component_overrides: locked_quote.presentment_component_overrides
    ).allocations
    self.class.persist!(
      charge:,
      presentment_currency: eligibility_decision.currency,
      presentment_total_cents:,
      presentment_gumroad_amount_cents:,
      allocations:,
      stripe_fx_quote_id: locked_quote.id,
      stripe_fx_quote_expires_at: locked_quote.expires_at,
      fx_rate: locked_quote.fx_rate,
      rounding_delta_cents: rounding_delta_cents
    )

    Result.new(
      processor_amount_cents: presentment_total_cents,
      processor_currency: eligibility_decision.currency,
      processor_gumroad_amount_cents: presentment_gumroad_amount_cents,
      stripe_fx_quote_id: locked_quote.stripe_fx_quote_id
    )
  rescue StandardError => e
    ErrorNotifier.notify(e, context: {
                           charge_id: charge.id,
                           charge_external_id: charge.external_id,
                           merchant_account_id: merchant_account.id,
                           presentment_currency: eligibility_decision.currency,
                         })
    Rails.logger.info("Buyer currency presentment fallback for charge #{charge.external_id}: #{e.class} #{e.message}")
    nil
  end

  private
    # Whether Gumroad's share of THIS charge really covers a round-down, checked against
    # the fee that was actually computed on the purchases rather than the fee the quote
    # predicted.
    #
    # Why the quote-time cap is not enough: the quote is minted while the buyer is still
    # on the checkout page, and Checkout::PresentmentRounding sizes the round-down against
    # the percentage fee it expects Gumroad to collect. Between then and the charge, that
    # fee can legitimately drop to zero — Gumroad Day starts (which is decided from the
    # current date in the seller's timezone, so it can flip mid-checkout) or someone turns
    # on the seller's fee-waiver flag. Purchase#calculate_fees then charges no percentage
    # fee, so there is no Gumroad share for the reduction to come out of and the seller
    # would silently receive less than their canonical proceeds.
    #
    # Charging the buyer the un-rounded amount is not an option: they confirmed the rounded
    # total, and charging anything else breaks the invariant this whole feature rests on.
    # So the charge fails closed instead — the buyer is asked to review the updated total,
    # and the reloaded checkout mints a fresh quote that will not round down (a waived
    # seller is excluded from rounding at quote time). This is rare by construction: it
    # needs a waiver to begin during one checkout session.
    def rounding_absorbable?(rounding_delta_cents)
      return true unless rounding_delta_cents.negative?

      # Only Gumroad's own percentage fee counts. gumroad_amount_cents also carries
      # affiliate credit and Gumroad-collected tax, and neither is Gumroad's to give up —
      # the affiliate is owed their cut and the tax gets remitted. fee_cents is no good
      # either: on a charge through a Gumroad-owned Stripe account it also contains the
      # processor's percentage and fixed costs, which Gumroad is only holding on its way to
      # Stripe, so a fee-waived sale can still show a positive fee_cents made up entirely of
      # those pass-through costs. Spending that on a price reduction would leave Gumroad
      # paying Stripe out of pocket, so the floor is built from
      # Purchase#gumroad_percentage_fee_cents, which is zero exactly when the percentage fee
      # is waived. Converted to presentment cents because the delta is a presentment-currency
      # amount.
      absorbable_presentment_cents = presentment_cents_for(purchases.sum { _1.gumroad_percentage_fee_cents }, locked_quote.fx_rate)
      return true if rounding_delta_cents.abs <= absorbable_presentment_cents

      @fallback_reason = "rounding_delta_exceeds_gumroad_fee"
      Rails.logger.info(
        "Buyer currency presentment fallback for charge #{charge.external_id}: " \
        "round-down of #{rounding_delta_cents.abs} exceeds Gumroad's fee of #{absorbable_presentment_cents}"
      )
      false
    end

    def presentment_cents_for(canonical_usd_cents, fx_rate)
      raise ArgumentError, "FX rate must be positive" unless fx_rate.positive?

      ((BigDecimal(canonical_usd_cents.to_s) / subunit_to_unit(Currency::USD)) / fx_rate * subunit_to_unit(eligibility_decision.currency)).round
    end
end
