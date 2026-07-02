# frozen_string_literal: true

require "spec_helper"

describe ChargePresentment do
  it "requires processor and presentment currency" do
    presentment = build(:charge_presentment, processor: nil, presentment_currency: nil)

    expect(presentment).not_to be_valid
    expect(presentment.errors).to include(:processor, :presentment_currency)
  end

  it "requires quote details for Stripe rows" do
    presentment = build(:charge_presentment,
                        stripe_fx_quote_id: nil,
                        stripe_fx_quote_expires_at: nil,
                        fx_rate: nil)

    expect(presentment).not_to be_valid
    expect(presentment.errors).to include(:stripe_fx_quote_id, :stripe_fx_quote_expires_at, :fx_rate)
  end

  it "allows quoteless rows for other processors" do
    # Local payment methods where the quote cannot lock and Phase 3 PayPal reuse this
    # table without the Stripe quote columns; they are nullable at the database level.
    presentment = build(:charge_presentment,
                        processor: "paypal",
                        stripe_fx_quote_id: nil,
                        stripe_fx_quote_expires_at: nil,
                        fx_rate: nil)

    expect(presentment).to be_valid
  end

  it "requires non-negative presentment amounts" do
    presentment = build(:charge_presentment, presentment_total_cents: -1, presentment_gumroad_amount_cents: -1)

    expect(presentment).not_to be_valid
    expect(presentment.errors).to include(:presentment_total_cents, :presentment_gumroad_amount_cents)
  end
end
