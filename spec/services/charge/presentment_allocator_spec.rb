# frozen_string_literal: true

describe Charge::PresentmentAllocator do
  describe "#allocations" do
    it "allocates one purchase's presentment components and reconciles to the charge totals" do
      tip = instance_double(Tip, value_usd_cents: 1_00)
      purchase = instance_double(Purchase,
                                 total_transaction_cents: 12_00,
                                 total_transaction_amount_for_gumroad_cents: 3_00,
                                 tip:,
                                 tax_cents: 80,
                                 gumroad_tax_cents: 20,
                                 shipping_cents: 2_00)

      allocation = described_class.new(
        purchases: [purchase],
        presentment_total_cents: 15_00,
        presentment_gumroad_amount_cents: 3_75
      ).allocations.sole

      expect(allocation).to have_attributes(purchase:,
                                            presentment_price_cents: 10_00,
                                            presentment_tip_cents: 1_25,
                                            presentment_seller_tax_cents: 1_00,
                                            presentment_gumroad_tax_cents: 25,
                                            presentment_shipping_cents: 2_50,
                                            presentment_total_cents: 15_00,
                                            presentment_gumroad_amount_cents: 3_75)
      expect(allocation.presentment_price_cents +
             allocation.presentment_tip_cents +
             allocation.presentment_seller_tax_cents +
             allocation.presentment_gumroad_tax_cents +
             allocation.presentment_shipping_cents).to eq(allocation.presentment_total_cents)
    end

    it "keeps an exact buyer-typed presentment tip and reconciles the line total" do
      tip = instance_double(Tip, value_usd_cents: 3_50)
      purchase = instance_double(Purchase,
                                 total_transaction_cents: 13_50,
                                 total_transaction_amount_for_gumroad_cents: 3_00,
                                 tip:,
                                 tax_cents: 0,
                                 gumroad_tax_cents: 0,
                                 shipping_cents: 0)

      allocation = described_class.new(
        purchases: [purchase],
        presentment_total_cents: 16_88,
        presentment_gumroad_amount_cents: 3_75,
        presentment_component_overrides: [[nil, 4_37, nil, nil, nil]]
      ).allocations.sole

      expect(allocation).to have_attributes(
        presentment_price_cents: 12_51,
        presentment_tip_cents: 4_37,
        presentment_total_cents: 16_88,
      )
    end

    it "splits an odd-cent presentment total across several purchases without losing cents" do
      # Three near-equal-weight items cannot split 10.01 evenly — the largest-remainder
      # pass must hand out the leftover cents instead of dropping them.
      purchases = [3_34, 3_33, 3_33].map do |total_transaction_cents|
        instance_double(Purchase,
                        total_transaction_cents:,
                        total_transaction_amount_for_gumroad_cents: 1_00,
                        tip: nil,
                        tax_cents: 0,
                        gumroad_tax_cents: 0,
                        shipping_cents: 0)
      end

      allocations = described_class.new(
        purchases:,
        presentment_total_cents: 10_01,
        presentment_gumroad_amount_cents: 3_01
      ).allocations

      expect(allocations.sum(&:presentment_total_cents)).to eq(10_01)
      expect(allocations.sum(&:presentment_gumroad_amount_cents)).to eq(3_01)
      allocations.each do |allocation|
        expect(allocation.presentment_price_cents +
               allocation.presentment_tip_cents +
               allocation.presentment_seller_tax_cents +
               allocation.presentment_gumroad_tax_cents +
               allocation.presentment_shipping_cents).to eq(allocation.presentment_total_cents)
      end
    end

    it "allocates per-purchase components for a mixed cart so each purchase reconciles to its own share" do
      tip = instance_double(Tip, value_usd_cents: 1_00)
      purchase_with_components = instance_double(Purchase,
                                                 total_transaction_cents: 12_00,
                                                 total_transaction_amount_for_gumroad_cents: 3_00,
                                                 tip:,
                                                 tax_cents: 80,
                                                 gumroad_tax_cents: 20,
                                                 shipping_cents: 2_00)
      plain_purchase = instance_double(Purchase,
                                       total_transaction_cents: 5_00,
                                       total_transaction_amount_for_gumroad_cents: 1_50,
                                       tip: nil,
                                       tax_cents: 0,
                                       gumroad_tax_cents: 0,
                                       shipping_cents: 0)

      allocations = described_class.new(
        purchases: [purchase_with_components, plain_purchase],
        presentment_total_cents: 21_37,
        presentment_gumroad_amount_cents: 5_63
      ).allocations

      expect(allocations.sum(&:presentment_total_cents)).to eq(21_37)
      expect(allocations.sum(&:presentment_gumroad_amount_cents)).to eq(5_63)
      allocations.each do |allocation|
        expect(allocation.presentment_price_cents +
               allocation.presentment_tip_cents +
               allocation.presentment_seller_tax_cents +
               allocation.presentment_gumroad_tax_cents +
               allocation.presentment_shipping_cents).to eq(allocation.presentment_total_cents)
      end
      expect(allocations.first.presentment_tip_cents).to be_positive
      expect(allocations.first.presentment_shipping_cents).to be_positive
      expect(allocations.second).to have_attributes(presentment_tip_cents: 0,
                                                    presentment_seller_tax_cents: 0,
                                                    presentment_gumroad_tax_cents: 0,
                                                    presentment_shipping_cents: 0)
    end

    it "caps a purchase's Gumroad share at its allocated presentment total and moves the displaced cent to a purchase with headroom" do
      # Reviewer regression case: the purchase totals and the Gumroad amounts round on
      # different bases, so purchase 2 (whose Gumroad portion is its entire canonical total)
      # wins the Gumroad split's rounding cent (132) even though its total split only got
      # 131. The allocator must cap that share at 131 and hand the cent to purchase 1.
      purchase_1 = instance_double(Purchase,
                                   total_transaction_cents: 99,
                                   total_transaction_amount_for_gumroad_cents: 53,
                                   tip: nil,
                                   tax_cents: 0,
                                   gumroad_tax_cents: 0,
                                   shipping_cents: 0)
      purchase_2 = instance_double(Purchase,
                                   total_transaction_cents: 1_64,
                                   total_transaction_amount_for_gumroad_cents: 1_64,
                                   tip: nil,
                                   tax_cents: 0,
                                   gumroad_tax_cents: 0,
                                   shipping_cents: 0)

      allocations = described_class.new(
        purchases: [purchase_1, purchase_2],
        presentment_total_cents: 2_10,
        presentment_gumroad_amount_cents: 1_74
      ).allocations

      expect(allocations.map(&:presentment_total_cents)).to eq([79, 1_31])
      expect(allocations.map(&:presentment_gumroad_amount_cents)).to eq([43, 1_31])
      expect(allocations.sum(&:presentment_gumroad_amount_cents)).to eq(1_74)
      allocations.each do |allocation|
        expect(allocation.presentment_gumroad_amount_cents).to be <= allocation.presentment_total_cents
      end
    end

    it "keeps Gumroad shares within each purchase's total when one purchase has zero canonical seller proceeds and residual cents are in play" do
      # Purchase 2's Gumroad amount equals its full canonical total (the seller nets nothing
      # on it), so its Gumroad share has zero headroom. At 0.8 USD per unit the raw splits
      # are totals [63, 62] but Gumroad shares [21, 63]: the Gumroad split's residual cent
      # lands on purchase 2, exceeding what the buyer paid for it. The cap must hold the
      # share at 62 and move the displaced cent to purchase 1's headroom.
      purchase_1 = instance_double(Purchase,
                                   total_transaction_cents: 50,
                                   total_transaction_amount_for_gumroad_cents: 17,
                                   tip: nil,
                                   tax_cents: 0,
                                   gumroad_tax_cents: 0,
                                   shipping_cents: 0)
      purchase_2 = instance_double(Purchase,
                                   total_transaction_cents: 50,
                                   total_transaction_amount_for_gumroad_cents: 50,
                                   tip: nil,
                                   tax_cents: 0,
                                   gumroad_tax_cents: 0,
                                   shipping_cents: 0)

      allocations = described_class.new(
        purchases: [purchase_1, purchase_2],
        presentment_total_cents: 1_25,
        presentment_gumroad_amount_cents: 84
      ).allocations

      expect(allocations.map(&:presentment_total_cents)).to eq([63, 62])
      expect(allocations.map(&:presentment_gumroad_amount_cents)).to eq([22, 62])
      expect(allocations.sum(&:presentment_gumroad_amount_cents)).to eq(84)
      allocations.each do |allocation|
        expect(allocation.presentment_gumroad_amount_cents).to be <= allocation.presentment_total_cents
      end
      expect(allocations.second.presentment_gumroad_amount_cents).to eq(allocations.second.presentment_total_cents)
    end

    it "raises when the charge-level Gumroad amount exceeds the presentment total" do
      # No distribution of shares can satisfy per-purchase caps if the charge-level Gumroad
      # amount itself is larger than the charge total; that input is corrupt, so fail loudly
      # (the orchestrator rescues and falls back to a canonical charge).
      purchase = instance_double(Purchase,
                                 total_transaction_cents: 10_00,
                                 total_transaction_amount_for_gumroad_cents: 10_00,
                                 tip: nil,
                                 tax_cents: 0,
                                 gumroad_tax_cents: 0,
                                 shipping_cents: 0)

      expect do
        described_class.new(
          purchases: [purchase],
          presentment_total_cents: 12_50,
          presentment_gumroad_amount_cents: 12_51
        ).allocations
      end.to raise_error(ArgumentError, /exceeds the presentment total/)
    end

    it "gives zero-weight purchases zero presentment cents" do
      # Gift checkouts create a 0-cent giftee purchase alongside the gifter purchase, so
      # allocation must not misallocate to zero-weight rows.
      purchase = instance_double(Purchase,
                                 total_transaction_cents: 10_00,
                                 total_transaction_amount_for_gumroad_cents: 3_00,
                                 tip: nil,
                                 tax_cents: 0,
                                 gumroad_tax_cents: 0,
                                 shipping_cents: 0)
      zero_cent_purchase = instance_double(Purchase,
                                           total_transaction_cents: 0,
                                           total_transaction_amount_for_gumroad_cents: 0,
                                           tip: nil,
                                           tax_cents: 0,
                                           gumroad_tax_cents: 0,
                                           shipping_cents: 0)

      allocations = described_class.new(
        purchases: [purchase, zero_cent_purchase],
        presentment_total_cents: 12_50,
        presentment_gumroad_amount_cents: 3_75
      ).allocations

      expect(allocations.first).to have_attributes(purchase:,
                                                   presentment_total_cents: 12_50,
                                                   presentment_gumroad_amount_cents: 3_75)
      expect(allocations.second).to have_attributes(purchase: zero_cent_purchase,
                                                    presentment_price_cents: 0,
                                                    presentment_tip_cents: 0,
                                                    presentment_seller_tax_cents: 0,
                                                    presentment_gumroad_tax_cents: 0,
                                                    presentment_shipping_cents: 0,
                                                    presentment_total_cents: 0,
                                                    presentment_gumroad_amount_cents: 0)
      expect(allocations.sum(&:presentment_total_cents)).to eq(12_50)
    end

    it "keeps the tax components at their exact converted value and carries a price-ending round-up on the price" do
      # Reviewer regression case: with the difference spread proportionally over every
      # component, a total rounded up to CA$16.49 reported CA$1.50 of tax where the exact
      # conversion (CA$16.37) gives CA$1.49 — a cosmetic cent labelled as tax collected, on
      # the checkout, the receipt and the persisted row. Tax must stay at the exact figure.
      purchase = instance_double(Purchase,
                                 total_transaction_cents: 11_00,
                                 total_transaction_amount_for_gumroad_cents: 3_00,
                                 tip: nil,
                                 tax_cents: 1_00,
                                 gumroad_tax_cents: 0,
                                 shipping_cents: 0)

      exact = described_class.new(
        purchases: [purchase],
        presentment_total_cents: 16_37,
        presentment_gumroad_amount_cents: 4_46
      ).allocations.sole
      rounded = described_class.new(
        purchases: [purchase],
        presentment_total_cents: 16_37,
        presentment_gumroad_amount_cents: 4_58,
        rounding_delta_cents: 12
      ).allocations.sole

      expect(rounded.presentment_seller_tax_cents).to eq(exact.presentment_seller_tax_cents)
      expect(rounded.presentment_price_cents).to eq(exact.presentment_price_cents + 12)
      expect(rounded.presentment_total_cents).to eq(16_49)
      expect(rounded.presentment_price_cents +
             rounded.presentment_tip_cents +
             rounded.presentment_seller_tax_cents +
             rounded.presentment_gumroad_tax_cents +
             rounded.presentment_shipping_cents).to eq(rounded.presentment_total_cents)
    end

    it "keeps the tax components at their exact converted value when the total is rounded down" do
      purchase = instance_double(Purchase,
                                 total_transaction_cents: 11_00,
                                 total_transaction_amount_for_gumroad_cents: 3_00,
                                 tip: nil,
                                 tax_cents: 60,
                                 gumroad_tax_cents: 40,
                                 shipping_cents: 0)

      exact = described_class.new(
        purchases: [purchase],
        presentment_total_cents: 16_37,
        presentment_gumroad_amount_cents: 4_46
      ).allocations.sole
      rounded = described_class.new(
        purchases: [purchase],
        presentment_total_cents: 16_37,
        presentment_gumroad_amount_cents: 4_08,
        rounding_delta_cents: -38
      ).allocations.sole

      expect(rounded.presentment_seller_tax_cents).to eq(exact.presentment_seller_tax_cents)
      expect(rounded.presentment_gumroad_tax_cents).to eq(exact.presentment_gumroad_tax_cents)
      expect(rounded.presentment_price_cents).to eq(exact.presentment_price_cents - 38)
      expect(rounded.presentment_total_cents).to eq(15_99)
    end

    it "spreads the difference across a multi-line cart's non-tax components in proportion to them" do
      taxed_purchase = instance_double(Purchase,
                                       total_transaction_cents: 11_00,
                                       total_transaction_amount_for_gumroad_cents: 3_00,
                                       tip: nil,
                                       tax_cents: 1_00,
                                       gumroad_tax_cents: 0,
                                       shipping_cents: 0)
      plain_purchase = instance_double(Purchase,
                                       total_transaction_cents: 5_00,
                                       total_transaction_amount_for_gumroad_cents: 1_50,
                                       tip: nil,
                                       tax_cents: 0,
                                       gumroad_tax_cents: 0,
                                       shipping_cents: 0)

      exact = described_class.new(
        purchases: [taxed_purchase, plain_purchase],
        presentment_total_cents: 21_37,
        presentment_gumroad_amount_cents: 5_63
      ).allocations
      rounded = described_class.new(
        purchases: [taxed_purchase, plain_purchase],
        presentment_total_cents: 21_37,
        presentment_gumroad_amount_cents: 5_75,
        rounding_delta_cents: 12
      ).allocations

      expect(rounded.sum(&:presentment_total_cents)).to eq(21_49)
      expect(rounded.map(&:presentment_seller_tax_cents)).to eq(exact.map(&:presentment_seller_tax_cents))
      expect(rounded.map(&:presentment_gumroad_tax_cents)).to eq(exact.map(&:presentment_gumroad_tax_cents))
      # Both lines carry part of the increase, weighted by their own non-tax money.
      expect(rounded.map(&:presentment_price_cents).zip(exact.map(&:presentment_price_cents)).map { _1 - _2 }.sum).to eq(12)
      rounded.each_with_index do |allocation, index|
        expect(allocation.presentment_price_cents).to be > exact[index].presentment_price_cents
      end
    end

    it "raises when a reduction is larger than the cart's non-tax money" do
      # The only way a reduction can fail: it asks for more than price + tip + shipping
      # can give up. Anything within that budget is safe, because a largest-remainder
      # portion is never larger than its own weight. The orchestrator's rescue turns this
      # into a fail-closed charge rather than rows that disagree with what was charged.
      purchase = instance_double(Purchase,
                                 total_transaction_cents: 10_00,
                                 total_transaction_amount_for_gumroad_cents: 10_00,
                                 tip: nil,
                                 tax_cents: 2_00,
                                 gumroad_tax_cents: 0,
                                 shipping_cents: 0)

      expect do
        described_class.new(
          purchases: [purchase],
          presentment_total_cents: 10_00,
          presentment_gumroad_amount_cents: 1_00,
          # 8_00 of the 10_00 total is price; asking for 8_01 back cannot be honoured
          # without dipping into the tax.
          rounding_delta_cents: -8_01
        ).allocations
      end.to raise_error(ArgumentError, /reduction of 801 exceeds the cart's 800 cents of non-tax components/)
    end

    it "spends a reduction down to the last non-tax cent without touching tax" do
      # The boundary case on the other side of the raise above: a reduction of exactly the
      # cart's non-tax money is allowed, takes the price to zero, and leaves the tax at its
      # exact converted value.
      purchase = instance_double(Purchase,
                                 total_transaction_cents: 10_00,
                                 total_transaction_amount_for_gumroad_cents: 10_00,
                                 tip: nil,
                                 tax_cents: 2_00,
                                 gumroad_tax_cents: 0,
                                 shipping_cents: 0)

      allocation = described_class.new(
        purchases: [purchase],
        presentment_total_cents: 10_00,
        presentment_gumroad_amount_cents: 1_00,
        rounding_delta_cents: -8_00
      ).allocations.sole

      expect(allocation).to have_attributes(presentment_price_cents: 0,
                                            presentment_seller_tax_cents: 2_00,
                                            presentment_total_cents: 2_00)
    end

    it "raises when only tax components are left to carry the difference" do
      # A tax-only cart has no honest place to put the difference. The quote's rescue turns
      # this into a canonical-USD checkout; the orchestrator's fails the charge closed.
      # Either way nothing is persisted that disagrees with what was charged.
      purchase = instance_double(Purchase,
                                 total_transaction_cents: 1_00,
                                 total_transaction_amount_for_gumroad_cents: 1_00,
                                 tip: nil,
                                 tax_cents: 1_00,
                                 gumroad_tax_cents: 0,
                                 shipping_cents: 0)

      expect do
        described_class.new(
          purchases: [purchase],
          presentment_total_cents: 1_00,
          presentment_gumroad_amount_cents: 1_00,
          rounding_delta_cents: 5
        ).allocations
      end.to raise_error(ArgumentError, /no non-tax component/)
    end
  end
end
