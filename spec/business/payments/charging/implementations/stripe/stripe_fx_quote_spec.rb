# frozen_string_literal: true

require "spec_helper"

describe StripeFxQuote do
  it "creates a locked payment quote with the scoped preview API version" do
    response = Stripe::StripeResponse.new
    response.data = {
      id: "fxq_test",
      lock_expires_at: 1.hour.from_now.to_i,
      to_currency: "usd",
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
      hash_including(stripe_version: described_class::API_VERSION,
                     stripe_account: "acct_test",
                     client: have_attributes(config: have_attributes(open_timeout: described_class::OPEN_TIMEOUT_SECONDS,
                                                                     read_timeout: described_class::READ_TIMEOUT_SECONDS,
                                                                     write_timeout: described_class::WRITE_TIMEOUT_SECONDS)))
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
      to_currency: "usd",
      rates: {
        cad: { exchange_rate: "0.800000000000000" }
      }
    }

    expect(Stripe).to receive(:raw_request).with(
      :post,
      "/v1/fx_quotes",
      hash_including(to_currency: Currency::USD, from_currencies: [Currency::CAD]),
      hash_including(stripe_version: described_class::API_VERSION,
                     client: have_attributes(config: have_attributes(open_timeout: described_class::OPEN_TIMEOUT_SECONDS,
                                                                     read_timeout: described_class::READ_TIMEOUT_SECONDS,
                                                                     write_timeout: described_class::WRITE_TIMEOUT_SECONDS)))
    ).and_return(response)

    quote = described_class.create(to_currency: Currency::USD, from_currency: Currency::CAD, stripe_account_id: nil)

    expect(quote.id).to eq("fxq_test")
  end

  it "rejects quotes that settle in a different currency than requested" do
    # Stripe can settle in a currency the connected account enabled through multi-currency
    # settlement; converting against the wrong settlement currency would charge the buyer a
    # different amount, so the mismatch must fall back to the canonical path.
    response = Stripe::StripeResponse.new
    response.data = {
      id: "fxq_test",
      lock_expires_at: 1.hour.from_now.to_i,
      to_currency: "eur",
      rates: {
        cad: { exchange_rate: "0.680000000000000" }
      }
    }
    allow(Stripe).to receive(:raw_request).and_return(response)

    expect do
      described_class.create(to_currency: Currency::USD, from_currency: Currency::CAD, stripe_account_id: "acct_test")
    end.to raise_error(StripeFxQuote::SettlementCurrencyMismatch, /settles in eur, expected usd/)
  end

  it "maps Stripe's request-time settlement-currency rejection to SettlementCurrencyMismatch" do
    # Some connected accounts settle in a non-USD currency; Stripe then rejects the quote
    # request itself instead of returning a mismatched quote (seen in production as
    # ChargeProcessorInvalidRequestError). Callers rescue SettlementCurrencyMismatch to
    # fall back to the canonical USD path, so this rejection must map to the same error.
    stripe_error = Stripe::InvalidRequestError.new(
      "The FX Quote's to_currency: \"usd\" must match the payment intent's settlement currency: \"cad\".",
      nil,
      http_status: 400
    )
    allow(Stripe).to receive(:raw_request).and_raise(stripe_error)

    expect do
      described_class.create(to_currency: Currency::USD, from_currency: Currency::CAD, stripe_account_id: "acct_test")
    end.to raise_error(StripeFxQuote::SettlementCurrencyMismatch, /must match the payment intent's settlement currency/)
  end

  it "re-raises other invalid-request errors unchanged" do
    stripe_error = Stripe::InvalidRequestError.new("No such account: acct_missing", nil, http_status: 400)
    allow(Stripe).to receive(:raw_request).and_raise(stripe_error)

    expect do
      described_class.create(to_currency: Currency::USD, from_currency: Currency::CAD, stripe_account_id: "acct_missing")
    end.to raise_error(ChargeProcessorInvalidRequestError)
  end
end
