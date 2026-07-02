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
  end
end
