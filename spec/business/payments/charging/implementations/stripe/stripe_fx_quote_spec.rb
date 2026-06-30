# frozen_string_literal: true

require "spec_helper"

describe StripeFxQuote do
  it "creates a locked payment quote with the scoped preview API version" do
    response = Stripe::StripeResponse.new
    response.data = {
      id: "fxq_test",
      lock_expires_at: 1.hour.from_now.to_i,
      rates: {
        cad: { exchange_rate: "0.800000000000000" }
      }
    }

    expect(Stripe).to receive(:raw_request).with(
      :post,
      "/v1/fx_quotes",
      {
        to_currency: Currency::USD,
        from_currencies: [Currency::CAD],
        lock_duration: "hour",
        usage: { type: "payment" },
      },
      {
        stripe_version: described_class::API_VERSION,
        stripe_account: "acct_test",
      }
    ).and_return(response)

    quote = described_class.create(to_currency: Currency::USD, from_currency: Currency::CAD, stripe_account_id: "acct_test")

    expect(quote).to have_attributes(id: "fxq_test", fx_rate: BigDecimal("0.8"))
    expect(quote.expires_at).to be_within(1.second).of(Time.zone.at(response.data[:lock_expires_at]))
  end

  it "creates platform-account quotes without Stripe-Account options" do
    response = Stripe::StripeResponse.new
    response.data = {
      id: "fxq_test",
      lock_expires_at: 1.hour.from_now.to_i,
      rates: {
        cad: { exchange_rate: "0.800000000000000" }
      }
    }

    expect(Stripe).to receive(:raw_request).with(
      :post,
      "/v1/fx_quotes",
      hash_including(to_currency: Currency::USD, from_currencies: [Currency::CAD]),
      { stripe_version: described_class::API_VERSION }
    ).and_return(response)

    quote = described_class.create(to_currency: Currency::USD, from_currency: Currency::CAD, stripe_account_id: nil)

    expect(quote.id).to eq("fxq_test")
  end
end
