# frozen_string_literal: true

class Charge::PresentmentAllocator
  Allocation = Struct.new(:purchase,
                          :presentment_price_cents,
                          :presentment_tip_cents,
                          :presentment_seller_tax_cents,
                          :presentment_gumroad_tax_cents,
                          :presentment_shipping_cents,
                          :presentment_total_cents,
                          :presentment_gumroad_amount_cents,
                          keyword_init: true)

  attr_reader :purchases, :presentment_total_cents, :presentment_gumroad_amount_cents

  def initialize(purchases:, presentment_total_cents:, presentment_gumroad_amount_cents:)
    @purchases = purchases
    @presentment_total_cents = presentment_total_cents
    @presentment_gumroad_amount_cents = presentment_gumroad_amount_cents
  end

  def allocations
    purchase_total_shares = Charge.allocate_by_largest_remainder(
      presentment_total_cents,
      purchases.map(&:total_transaction_cents),
      purchases.sum(&:total_transaction_cents)
    )
    gumroad_amount_shares = gumroad_amount_shares_within(purchase_total_shares)

    purchases.each_with_index.map do |purchase, index|
      build_allocation(
        purchase:,
        presentment_total_cents: purchase_total_shares[index],
        presentment_gumroad_amount_cents: gumroad_amount_shares[index]
      )
    end
  end

  private
    # Splits the charge-level Gumroad amount across purchases without ever giving a purchase
    # a Gumroad share larger than that purchase's own presentment total. The purchase totals
    # and the Gumroad amounts are rounded on different bases (transaction totals vs Gumroad
    # portions), so a purchase whose Gumroad portion is its entire canonical total can win a
    # rounding cent on the Gumroad split that its total split did not get — which would record
    # Gumroad receiving more from the purchase than the buyer paid for it. Any capped-off
    # cents move to the earliest purchases that still have headroom, keeping the result
    # deterministic and the shares summing to the charge-level Gumroad amount.
    def gumroad_amount_shares_within(purchase_total_shares)
      if presentment_gumroad_amount_cents > purchase_total_shares.sum
        raise ArgumentError, "presentment Gumroad amount (#{presentment_gumroad_amount_cents}) exceeds the presentment total (#{purchase_total_shares.sum})"
      end

      shares = Charge.allocate_by_largest_remainder(
        presentment_gumroad_amount_cents,
        purchases.map(&:total_transaction_amount_for_gumroad_cents),
        purchases.sum(&:total_transaction_amount_for_gumroad_cents)
      )
      capped_shares = shares.zip(purchase_total_shares).map { |share, total_share| share.clamp(0, total_share) }

      displaced_cents = presentment_gumroad_amount_cents - capped_shares.sum
      purchase_total_shares.each_index do |index|
        break if displaced_cents.zero?

        headroom = purchase_total_shares[index] - capped_shares[index]
        step = [displaced_cents, headroom].min
        capped_shares[index] += step
        displaced_cents -= step
      end

      capped_shares
    end

    def build_allocation(purchase:, presentment_total_cents:, presentment_gumroad_amount_cents:)
      component_shares = Charge.allocate_by_largest_remainder(
        presentment_total_cents,
        canonical_component_cents(purchase),
        purchase.total_transaction_cents
      )

      Allocation.new(
        purchase:,
        presentment_price_cents: component_shares[0],
        presentment_tip_cents: component_shares[1],
        presentment_seller_tax_cents: component_shares[2],
        presentment_gumroad_tax_cents: component_shares[3],
        presentment_shipping_cents: component_shares[4],
        presentment_total_cents:,
        presentment_gumroad_amount_cents:
      )
    end

    def canonical_component_cents(purchase)
      tip_cents = purchase.tip&.value_usd_cents.to_i
      seller_tax_cents = purchase.tax_cents.to_i
      gumroad_tax_cents = purchase.gumroad_tax_cents.to_i
      shipping_cents = purchase.shipping_cents.to_i
      price_cents = purchase.total_transaction_cents.to_i - tip_cents - seller_tax_cents - gumroad_tax_cents - shipping_cents

      [[price_cents, 0].max, tip_cents, seller_tax_cents, gumroad_tax_cents, shipping_cents]
    end
end
