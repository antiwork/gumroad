# frozen_string_literal: true

require "spec_helper"

describe UpdateCurrenciesWorker do
  describe "#perform" do
    let(:worker) { described_class.new }

    def enable_stripe_fx_quotes
      allow(Rails.env).to receive(:development?).and_return(false)
      allow(Rails.env).to receive(:test?).and_return(false)
    end

    it "updates currencies from the backup rates in test" do
      worker.currency_namespace.set("AUD", "0.1111")
      expect(worker.get_rate("AUD")).to eq("0.1111")

      worker.perform

      expect(worker.get_rate("AUD")).to eq("0.969509")
    end

    it "populates Redis with Stripe FX quote rates" do
      enable_stripe_fx_quotes
      quote = {
        "rates" => {
          "aud" => { "exchange_rate" => 0.5 },
          "eur" => { "exchange_rate" => 1.25 },
        },
      }

      expect(Stripe::FxQuote).to receive(:create).with(
        to_currency: "usd",
        from_currencies: match_array((STRIPE_FX_CURRENCY_CHOICES - ["USD"]).map(&:downcase)),
        lock_duration: "none"
      ).and_return(quote)

      worker.perform

      expect(worker.currency_namespace.get("AUD")).to eq("2.0")
      expect(worker.currency_namespace.get("EUR")).to eq("0.8")
      expect(worker.currency_namespace.get("USD")).to eq("1")
    end

    it "falls back to backup rates when Stripe FX quotes fail" do
      enable_stripe_fx_quotes
      error = Stripe::RateLimitError.new("rate limited")
      report = instance_double(ErrorNotifier::SentryReportAdapter)

      allow(Stripe::FxQuote).to receive(:create).and_raise(error)
      expect(Rails.logger).to receive(:warn).with(/Stripe FX Quotes API failed/)
      expect(report).to receive(:severity=).with("warning")
      expect(ErrorNotifier).to receive(:notify)
        .with(error, currencies: match_array(STRIPE_FX_CURRENCY_CHOICES - ["USD"]))
        .and_yield(report)

      expect { worker.perform }.not_to raise_error
      expect(worker.currency_namespace.get("AUD")).to eq("0.969509")
    end
  end
end
