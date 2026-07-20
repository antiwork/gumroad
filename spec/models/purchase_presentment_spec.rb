# frozen_string_literal: true

require "spec_helper"

describe PurchasePresentment do
  it "requires processor and presentment currency" do
    presentment = build(:purchase_presentment, processor: nil, presentment_currency: nil)

    expect(presentment).not_to be_valid
    expect(presentment.errors).to include(:processor, :presentment_currency)
  end

  it "requires non-negative component amounts" do
    presentment = build(:purchase_presentment,
                        presentment_price_cents: -1,
                        presentment_tip_cents: -1,
                        presentment_seller_tax_cents: -1,
                        presentment_gumroad_tax_cents: -1,
                        presentment_shipping_cents: -1,
                        presentment_total_cents: -1,
                        presentment_gumroad_amount_cents: -1)

    expect(presentment).not_to be_valid
    expect(presentment.errors).to include(:presentment_price_cents,
                                          :presentment_tip_cents,
                                          :presentment_seller_tax_cents,
                                          :presentment_gumroad_tax_cents,
                                          :presentment_shipping_cents,
                                          :presentment_total_cents,
                                          :presentment_gumroad_amount_cents)
  end

  it "requires a charge presentment for Stripe rows" do
    presentment = build(:purchase_presentment, charge_presentment: nil)

    expect(presentment).not_to be_valid
    expect(presentment.errors).to include(:charge_presentment)
  end

  it "requires component amounts to sum to the presentment total" do
    presentment = build(:purchase_presentment, presentment_total_cents: 13_49)

    expect(presentment).not_to be_valid
    expect(presentment.errors).to include(:presentment_total_cents)
  end

  it "rejects a Gumroad amount larger than the presentment total" do
    presentment = build(:purchase_presentment, presentment_gumroad_amount_cents: 13_51)

    expect(presentment).not_to be_valid
    expect(presentment.errors).to include(:presentment_gumroad_amount_cents)
  end

  it "allows a Gumroad amount equal to the presentment total" do
    # A purchase where the seller nets nothing (Gumroad's cut is the whole amount) is a
    # legitimate boundary, not a violation.
    presentment = build(:purchase_presentment, presentment_gumroad_amount_cents: 13_50)

    expect(presentment).to be_valid
  end
end
