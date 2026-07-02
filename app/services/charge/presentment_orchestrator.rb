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

  def initialize(charge:, merchant_account:, purchases:, amount_cents:, gumroad_amount_cents:, eligibility_decision:, locked_quote:)
    @charge = charge
    @merchant_account = merchant_account
    @purchases = purchases
    @amount_cents = amount_cents
    @gumroad_amount_cents = gumroad_amount_cents
    @eligibility_decision = eligibility_decision
    @locked_quote = locked_quote
  end

  def perform
    return unless eligibility_decision.eligible?

    # The buyer must be charged exactly the verified locked total they last saw; this
    # orchestrator never mints a fresh quote of its own.
    presentment_total_cents = locked_quote.presentment_total_cents
    presentment_gumroad_amount_cents = presentment_cents_for(gumroad_amount_cents, locked_quote.fx_rate)

    persist_presentment!(quote: locked_quote, presentment_total_cents:, presentment_gumroad_amount_cents:)

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
    def persist_presentment!(quote:, presentment_total_cents:, presentment_gumroad_amount_cents:)
      ActiveRecord::Base.transaction do
        purchases.each { _1.purchase_presentment&.destroy! }
        charge.charge_presentment&.destroy!

        charge_presentment = charge.create_charge_presentment!(
          processor: StripeChargeProcessor.charge_processor_id,
          presentment_currency: eligibility_decision.currency,
          presentment_total_cents:,
          presentment_gumroad_amount_cents:,
          stripe_fx_quote_id: quote.id,
          stripe_fx_quote_expires_at: quote.expires_at,
          fx_rate: quote.fx_rate
        )

        allocator = Charge::PresentmentAllocator.new(purchases:, presentment_total_cents:, presentment_gumroad_amount_cents:)
        allocator.allocations.each do |allocation|
          allocation.purchase.create_purchase_presentment!(
            charge_presentment:,
            processor: StripeChargeProcessor.charge_processor_id,
            presentment_currency: eligibility_decision.currency,
            presentment_price_cents: allocation.presentment_price_cents,
            presentment_tip_cents: allocation.presentment_tip_cents,
            presentment_seller_tax_cents: allocation.presentment_seller_tax_cents,
            presentment_gumroad_tax_cents: allocation.presentment_gumroad_tax_cents,
            presentment_shipping_cents: allocation.presentment_shipping_cents,
            presentment_total_cents: allocation.presentment_total_cents,
            presentment_gumroad_amount_cents: allocation.presentment_gumroad_amount_cents
          )
        end
      end
    end

    def presentment_cents_for(canonical_usd_cents, fx_rate)
      raise ArgumentError, "FX rate must be positive" unless fx_rate.positive?

      ((BigDecimal(canonical_usd_cents.to_s) / subunit_to_unit(Currency::USD)) / fx_rate * subunit_to_unit(eligibility_decision.currency)).round
    end
end
