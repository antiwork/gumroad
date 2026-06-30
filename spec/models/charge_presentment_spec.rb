# frozen_string_literal: true

require "spec_helper"

describe ChargePresentment do
  it "requires processor presentment and quote details" do
    presentment = build(:charge_presentment,
                        processor: nil,
                        presentment_currency: nil,
                        stripe_fx_quote_id: nil,
                        stripe_fx_quote_expires_at: nil,
                        fx_rate: nil)

    expect(presentment).not_to be_valid
    expect(presentment.errors).to include(:processor, :presentment_currency, :stripe_fx_quote_id, :stripe_fx_quote_expires_at, :fx_rate)
  end

  it "requires non-negative presentment amounts" do
    presentment = build(:charge_presentment, presentment_total_cents: -1, presentment_gumroad_amount_cents: -1)

    expect(presentment).not_to be_valid
    expect(presentment.errors).to include(:presentment_total_cents, :presentment_gumroad_amount_cents)
  end
end
