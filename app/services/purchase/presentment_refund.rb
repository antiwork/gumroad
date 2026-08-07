# frozen_string_literal: true

class Purchase::PresentmentRefund
  Result = Struct.new(:currency,
                      :presentment_amount_cents,
                      :presentment_price_cents,
                      :presentment_tip_cents,
                      :presentment_seller_tax_cents,
                      :presentment_gumroad_tax_cents,
                      :presentment_shipping_cents,
                      keyword_init: true) do
    def json_data
      {
        presentment_currency: currency,
        presentment_amount_cents:,
        presentment_price_cents:,
        presentment_tip_cents:,
        presentment_seller_tax_cents:,
        presentment_gumroad_tax_cents:,
        presentment_shipping_cents:,
      }
    end
  end

  COMPONENT_KEYS = %i[
    presentment_price_cents
    presentment_tip_cents
    presentment_seller_tax_cents
    presentment_gumroad_tax_cents
    presentment_shipping_cents
  ].freeze

  DerivedRefund = Struct.new(:canonical_gross_refund_cents, :presentment_refund, keyword_init: true)

  # Inverse mapping for refunds initiated at the processor (e.g. Stripe dashboard refunds
  # arriving via webhook, settlement declines): given the buyer-presentment amount that was
  # actually refunded, derive the canonical (USD) gross refund cents for the canonical
  # refund/balance records plus the presentment snapshot to persist on the refund.
  # Returns nil when no consistent derivation is possible, so callers fail closed.
  #
  # Every balance here is the PURCHASE's, never the charge's. On a multi-item cart one
  # PaymentIntent covers several purchases, each with its own purchase_presentment row
  # against the shared charge_presentment, so a refund aimed at one line must clamp to
  # that line's presentment cents. Clamping against the charge total instead would let a
  # refund of one item send back money for the whole cart — Stripe would accept it,
  # because the charge really does hold that much.
  def self.from_presentment_amount(purchase:, presentment_amount_cents:)
    presentment = purchase.purchase_presentment
    presentment_amount_cents = presentment_amount_cents.to_i
    return nil if presentment.blank? || presentment_amount_cents <= 0 || presentment.presentment_total_cents.to_i <= 0

    # A prior refund without a presentment snapshot makes the remaining presentment
    # balance unknowable (its canonical cents already reduced gross_amount_refundable_cents
    # but consumed zero presentment cents here), so fail closed rather than allocate the
    # new refund against a skewed balance.
    # Failed refunds never delivered money, so they consume no presentment balance —
    # exclude them everywhere prior refunds are summed here (mirrors
    # Purchase#amount_refunded_cents), or a bounced full refund would leave the
    # remaining presentment balance at zero and block the re-refund.
    prior_refunds = purchase.refunds.effective.to_a
    return nil if prior_refunds.any? { _1.presentment_amount_cents.to_i <= 0 }

    refunded_presentment_cents = prior_refunds.sum { _1.presentment_amount_cents.to_i }
    remaining_presentment_cents = presentment.presentment_total_cents - refunded_presentment_cents
    return nil if presentment_amount_cents > remaining_presentment_cents

    canonical_gross_refund_cents = if presentment_amount_cents == remaining_presentment_cents
      purchase.gross_amount_refundable_cents
    else
      # Allocate against the REMAINING presentment/canonical balances (not the original
      # totals) so repeated partial refunds cannot exhaust the canonical refundable amount
      # through rounding before the presentment charge is fully refunded.
      refunded_share = Charge.allocate_by_largest_remainder(
        purchase.gross_amount_refundable_cents,
        [presentment_amount_cents, remaining_presentment_cents - presentment_amount_cents],
        remaining_presentment_cents
      ).first
      [refunded_share, purchase.gross_amount_refundable_cents].min
    end
    return nil if canonical_gross_refund_cents <= 0

    presentment_refund = new(purchase:, canonical_gross_refund_cents:)
                           .result_for_presentment_amount(presentment_amount_cents)
    return nil if presentment_refund.blank?

    DerivedRefund.new(canonical_gross_refund_cents:, presentment_refund:)
  end

  attr_reader :purchase, :canonical_gross_refund_cents

  def initialize(purchase:, canonical_gross_refund_cents:)
    @purchase = purchase
    @canonical_gross_refund_cents = canonical_gross_refund_cents.to_i
  end

  def result
    return nil if purchase_presentment.blank? || canonical_gross_refund_cents <= 0

    # Snapshotless-prior guard: see .from_presentment_amount for why remaining
    # presentment becomes unknowable and we fail closed instead of allocating skewed.
    return nil if purchase.refunds.effective.any? { _1.presentment_amount_cents.to_i <= 0 }

    component_cents = remaining_component_cents
    # The original-total allocator could overdraw a component before exhausting the total.
    return nil if component_cents.any?(&:negative?)

    if refunds_remaining_presentment_amount?
      amount_cents = remaining_presentment_amount_cents
      return nil if amount_cents <= 0

      build_result(amount_cents:, component_cents:)
    else
      return nil if remaining_presentment_amount_cents <= 0

      amount_cents = partial_presentment_amount_cents
      return nil if amount_cents <= 0

      build_result(amount_cents:, component_cents: allocate_components(amount_cents, component_cents))
    end
  end

  # Builds a snapshot for a refund whose presentment amount is already known exactly
  # (processor-initiated refunds); the components are allocated to match that amount.
  def result_for_presentment_amount(presentment_amount_cents)
    return nil if purchase_presentment.blank? || presentment_amount_cents.to_i <= 0

    component_cents = remaining_component_cents
    return nil if component_cents.any?(&:negative?)

    if presentment_amount_cents == remaining_presentment_amount_cents
      build_result(amount_cents: presentment_amount_cents, component_cents:)
    else
      build_result(amount_cents: presentment_amount_cents,
                   component_cents: allocate_components(presentment_amount_cents, component_cents))
    end
  end

  # Builds a snapshot for a standalone Gumroad-tax (VAT) refund: the refund consists
  # entirely of the remaining presentment Gumroad-tax component, with no price, tip,
  # seller-tax, or shipping share. Returns nil when no consistent tax-only amount
  # remains, so callers fail closed.
  def tax_only_result
    return nil if purchase_presentment.blank? || canonical_gross_refund_cents <= 0

    # Snapshotless-prior guard: see .from_presentment_amount for why remaining
    # presentment becomes unknowable and we fail closed instead of allocating skewed.
    return nil if purchase.refunds.effective.any? { _1.presentment_amount_cents.to_i <= 0 }

    remaining_tax_cents = purchase_presentment.presentment_gumroad_tax_cents.to_i -
      refunded_presentment_cents_for(:presentment_gumroad_tax_cents)
    return nil if remaining_tax_cents <= 0 || remaining_tax_cents > remaining_presentment_amount_cents

    build_result(amount_cents: remaining_tax_cents,
                 component_cents: [0, 0, 0, remaining_tax_cents, 0])
  end

  private
    def purchase_presentment
      purchase.purchase_presentment
    end

    def refunds_remaining_presentment_amount?
      canonical_gross_refund_cents >= purchase.gross_amount_refundable_cents
    end

    def partial_presentment_amount_cents
      # Allocate against the REMAINING presentment/canonical balances (not the
      # original totals), same invariant as .from_presentment_amount: repeated
      # seller partials must not exhaust presentment cents through rounding while
      # canonical refundable cents remain (or drive component remainders negative).
      refunded_share = Charge.allocate_by_largest_remainder(
        remaining_presentment_amount_cents,
        [canonical_gross_refund_cents, purchase.gross_amount_refundable_cents - canonical_gross_refund_cents],
        purchase.gross_amount_refundable_cents
      ).first
      [refunded_share, remaining_presentment_amount_cents].min
    end

    def allocate_components(amount_cents, component_cents)
      Charge.allocate_by_largest_remainder(
        amount_cents,
        component_cents,
        remaining_presentment_amount_cents
      )
    end

    def remaining_component_cents
      COMPONENT_KEYS.map { |key| purchase_presentment.public_send(key).to_i - refunded_presentment_cents_for(key) }
    end

    def remaining_presentment_amount_cents
      purchase_presentment.presentment_total_cents - refunded_presentment_cents_for(:presentment_amount_cents)
    end

    def refunded_presentment_cents_for(key)
      # Effective only: a failed refund's presentment cents came back to us, so they
      # are still available to refund again.
      purchase.refunds.effective.sum { _1.public_send(key).to_i }
    end

    def build_result(amount_cents:, component_cents:)
      Result.new(currency: purchase_presentment.presentment_currency,
                 presentment_amount_cents: amount_cents,
                 presentment_price_cents: component_cents[0],
                 presentment_tip_cents: component_cents[1],
                 presentment_seller_tax_cents: component_cents[2],
                 presentment_gumroad_tax_cents: component_cents[3],
                 presentment_shipping_cents: component_cents[4])
    end
end
