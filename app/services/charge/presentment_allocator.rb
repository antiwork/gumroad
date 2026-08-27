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

  # One cart line's canonical (USD) money, with its components always in the order
  # price, tip, seller tax, Gumroad tax, shipping.
  Line = Struct.new(:canonical_total_cents, :canonical_component_cents, keyword_init: true)
  LineAllocation = Struct.new(:presentment_total_cents, :presentment_component_cents, keyword_init: true)

  # Which components a price-ending rounding difference is allowed to land on: the price,
  # the tip and the shipping, and never either tax component (indexes 2 and 3). The
  # difference is spread proportionally across all three at once, not preferentially.
  #
  # Tax is excluded because the tax figures are not ours to move. They are computed from
  # the canonical USD amounts, they are what the seller remits or what Gumroad remits as
  # marketplace facilitator, and they appear as tax on the checkout page, on the receipt
  # and on the persisted presentment rows. If the rounding difference were spread over
  # every component proportionally, part of a purely cosmetic price adjustment would be
  # labelled as tax collected — e.g. a CA$16.49 total showing CA$2.15 of tax where the
  # exact conversion gives CA$2.14. The difference is Gumroad's, so it is carried on the
  # non-tax lines and the tax lines keep the exact converted figure.
  ROUNDING_ABSORBING_COMPONENT_INDEXES = [0, 1, 4].freeze

  # The one rounding procedure for splitting a presentment total across cart lines and,
  # within each line, across its money components. Checkout::BuyerCurrencyQuote runs this
  # at quote time to tell the browser what each line should display, and #allocations runs
  # it again at charge time over the same canonical amounts to persist the purchase rows —
  # sharing the code is what guarantees the checkout page, the charged total, and the
  # receipt can never disagree by a rounding cent.
  #
  # presentment_total_cents is the EXACT converted total (canonical USD at the quote's FX
  # rate), never the rounded one, so every component is derived from the true conversion.
  # rounding_delta_cents is how far the price-ending rounding then moved the charged total
  # (see Checkout::PresentmentRounding); it is added on top of the exact components,
  # touching only the non-tax ones. The returned line totals therefore sum to
  # presentment_total_cents + rounding_delta_cents, which is what the buyer is charged.
  def self.allocate_lines(presentment_total_cents:, lines:, rounding_delta_cents: 0, presentment_component_overrides: nil)
    line_total_shares = Charge.allocate_by_largest_remainder(
      presentment_total_cents,
      lines.map(&:canonical_total_cents),
      lines.sum(&:canonical_total_cents)
    )

    component_shares = lines.each_with_index.map do |line, index|
      Charge.allocate_by_largest_remainder(
        line_total_shares[index],
        line.canonical_component_cents,
        line.canonical_total_cents
      )
    end
    component_shares = apply_rounding_delta(component_shares, rounding_delta_cents.to_i) unless rounding_delta_cents.to_i.zero?
    component_shares = apply_presentment_component_overrides(component_shares, presentment_component_overrides) if presentment_component_overrides.present?

    component_shares.map do |shares|
      LineAllocation.new(presentment_total_cents: shares.sum, presentment_component_cents: shares)
    end
  end

  # Spreads the rounding difference over the non-tax components of the cart, proportionally
  # to how large each of those components is, so a multi-line cart's lines each carry the
  # part of the difference that belongs to them.
  #
  # A largest-remainder portion is never larger than its own weight when the amount being
  # split is no larger than the total weight, so a reduction sized within the cart's
  # non-tax money can never push a component below zero. A reduction LARGER than that
  # money has nowhere to come from, so it raises instead — see the caller notes on what
  # each caller does with that.
  def self.apply_rounding_delta(component_shares, delta_cents)
    shares = component_shares.map(&:dup)
    absorbing_positions = shares.each_index.flat_map do |line_index|
      ROUNDING_ABSORBING_COMPONENT_INDEXES.map { |component_index| [line_index, component_index] }
    end
    weights = absorbing_positions.map { |line_index, component_index| shares[line_index][component_index] }

    if delta_cents.negative? && delta_cents.abs > weights.sum
      raise ArgumentError, "reduction of #{delta_cents.abs} exceeds the cart's #{weights.sum} cents of non-tax components"
    end
    if weights.sum.zero?
      # A cart with nothing but tax behind it has no honest place to put an increase
      # either. This cannot happen for a real cart (tax is computed from the price, so a
      # cart with no price has no tax), so treat it as a defect rather than inventing a
      # placement.
      raise ArgumentError, "no non-tax component can carry the #{delta_cents}-cent rounding difference"
    end

    portions = Charge.allocate_by_largest_remainder(delta_cents.abs, weights, weights.sum)
    sign = delta_cents.negative? ? -1 : 1
    absorbing_positions.each_with_index do |(line_index, component_index), position|
      shares[line_index][component_index] += sign * portions[position]
    end

    shares
  end
  private_class_method :apply_rounding_delta

  def self.apply_presentment_component_overrides(component_shares, overrides)
    shares = component_shares.map(&:dup)
    overrides.to_a.each_with_index do |line_overrides, line_index|
      next if line_overrides.blank?

      line_overrides.each_with_index do |desired_cents, component_index|
        next if desired_cents.nil?

        diff = desired_cents.to_i - shares.fetch(line_index).fetch(component_index).to_i
        next if diff.zero?

        compensation_index = (ROUNDING_ABSORBING_COMPONENT_INDEXES - [component_index]).find do |index|
          diff.negative? || shares[line_index][index] >= diff
        end
        raise ArgumentError, "presentment component override has no component to carry #{diff} cents" if compensation_index.nil?

        shares[line_index][component_index] += diff
        shares[line_index][compensation_index] -= diff
      end
    end
    shares
  end
  private_class_method :apply_presentment_component_overrides

  attr_reader :purchases, :presentment_total_cents, :presentment_gumroad_amount_cents, :rounding_delta_cents, :presentment_component_overrides

  # presentment_total_cents is the EXACT converted total; rounding_delta_cents is how far
  # the price-ending rounding moved the charged total away from it (see #allocate_lines).
  # presentment_gumroad_amount_cents already includes the difference, because Gumroad's
  # share of the charge is what absorbs it.
  def initialize(purchases:, presentment_total_cents:, presentment_gumroad_amount_cents:, rounding_delta_cents: 0, presentment_component_overrides: nil)
    @purchases = purchases
    @presentment_total_cents = presentment_total_cents
    @presentment_gumroad_amount_cents = presentment_gumroad_amount_cents
    @rounding_delta_cents = rounding_delta_cents.to_i
    @presentment_component_overrides = presentment_component_overrides
  end

  def allocations
    line_allocations = self.class.allocate_lines(
      presentment_total_cents:,
      rounding_delta_cents:,
      presentment_component_overrides:,
      lines: purchases.map do |purchase|
        Line.new(
          canonical_total_cents: purchase.total_transaction_cents,
          canonical_component_cents: canonical_component_cents(purchase)
        )
      end
    )
    gumroad_amount_shares = gumroad_amount_shares_within(line_allocations.map(&:presentment_total_cents))

    purchases.each_with_index.map do |purchase, index|
      component_shares = line_allocations[index].presentment_component_cents

      Allocation.new(
        purchase:,
        presentment_price_cents: component_shares[0],
        presentment_tip_cents: component_shares[1],
        presentment_seller_tax_cents: component_shares[2],
        presentment_gumroad_tax_cents: component_shares[3],
        presentment_shipping_cents: component_shares[4],
        presentment_total_cents: line_allocations[index].presentment_total_cents,
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

    def canonical_component_cents(purchase)
      tip_cents = purchase.tip&.value_usd_cents.to_i
      seller_tax_cents = purchase.tax_cents.to_i
      gumroad_tax_cents = purchase.gumroad_tax_cents.to_i
      shipping_cents = purchase.shipping_cents.to_i
      price_cents = purchase.total_transaction_cents.to_i - tip_cents - seller_tax_cents - gumroad_tax_cents - shipping_cents

      [[price_cents, 0].max, tip_cents, seller_tax_cents, gumroad_tax_cents, shipping_cents]
    end
end
