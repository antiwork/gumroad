# frozen_string_literal: true

require "spec_helper"

describe ChargePresentment do
  it "requires processor and presentment currency" do
    presentment = build(:charge_presentment, processor: nil, presentment_currency: nil)

    expect(presentment).not_to be_valid
    expect(presentment.errors).to include(:processor, :presentment_currency)
  end

  it "allows Stripe rows with no quote at all (quote-less method-forced presentment)" do
    # A method-forced local payment method charging a product priced in the forced
    # currency has no FX conversion, so no quote exists by design.
    presentment = build(:charge_presentment,
                        stripe_fx_quote_id: nil,
                        stripe_fx_quote_expires_at: nil,
                        fx_rate: nil)

    expect(presentment).to be_valid
  end

  it "rejects Stripe rows with a partially persisted quote" do
    presentment = build(:charge_presentment,
                        stripe_fx_quote_id: "fxq_partial",
                        stripe_fx_quote_expires_at: nil,
                        fx_rate: nil)

    expect(presentment).not_to be_valid
    expect(presentment.errors).to include(:base)
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
