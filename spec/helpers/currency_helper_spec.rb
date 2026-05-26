# frozen_string_literal: true

require "spec_helper"

describe CurrencyHelper do
  describe "#get_rate" do
    def enable_stripe_fx_quotes
      allow(Rails.env).to receive(:development?).and_return(false)
      allow(Rails.env).to receive(:test?).and_return(false)
    end

    it "returns the correct value" do
      expect(get_rate("JPY")).to eq "78.3932"
      expect(get_rate("GBP")).to eq "0.652571"
    end

    it "returns the cached value when present" do
      currency_namespace.set("JPY", "149.25")

      expect(Stripe::FxQuote).not_to receive(:create)
      expect(get_rate("JPY")).to eq "149.25"
    end

    it "fetches a Stripe FX quote and caches it when Redis is empty" do
      enable_stripe_fx_quotes
      quote = { "rates" => { "eur" => { "exchange_rate" => 1.25 } } }

      expect(Stripe::FxQuote).to receive(:create).with(
        to_currency: "usd",
        from_currencies: ["eur"],
        lock_duration: "none"
      ).and_return(quote)

      expect(get_rate("EUR")).to eq "0.8"
      expect(currency_namespace.get("EUR")).to eq "0.8"
    end

    it "returns the backup rate when Stripe FX quotes fail" do
      enable_stripe_fx_quotes
      error = Stripe::APIError.new("Stripe is down")
      report = instance_double(ErrorNotifier::SentryReportAdapter)

      allow(Stripe::FxQuote).to receive(:create).and_raise(error)
      expect(Rails.logger).to receive(:warn).with(/Stripe FX Quotes API failed/)
      expect(report).to receive(:severity=).with("warning")
      expect(ErrorNotifier).to receive(:notify).with(error, currencies: ["EUR"]).and_yield(report)

      expect(get_rate("EUR")).to eq "0.81127"
      expect(currency_namespace.get("EUR")).to eq "0.81127"
    end
  end

  describe "#get_usd_cents" do
    it "converts money amounts correctly" do
      expect(get_usd_cents("JPY", 100)).to eq 128
      expect(get_usd_cents("GBP", 100)).to eq 153
    end
  end

  describe "#usd_cents_to_currency" do
    it "converts money amounts correctly" do
      expect(usd_cents_to_currency("JPY", 127)).to eq 100
      expect(usd_cents_to_currency("GBP", 153)).to eq 100
    end
  end

  describe "#symbol_for" do
    it "returns the correct value" do
      expect(symbol_for(:usd)).to eq "$"
      expect(symbol_for(:gbp)).to eq "£"
    end

    it "falls back to USD for unknown currency types" do
      expect(symbol_for(:xyz)).to eq "$"
    end
  end

  describe "#min_price_for" do
    it "returns the correct value" do
      expect(min_price_for(:usd)).to eq 99
      expect(min_price_for(:gbp)).to eq 59
    end

    it "falls back to USD for unknown currency types" do
      expect(min_price_for(:xyz)).to eq 99
    end
  end

  describe "#string_to_price_cents" do
    it "ignores the comma" do
      expect(string_to_price_cents(:usd, "1,200")).to eq 120_000
      expect(string_to_price_cents(:usd, "1,200.99")).to eq 120_099
    end

    it "handles multiple decimal points by keeping only the first" do
      expect(string_to_price_cents(:usd, "50.00.000")).to eq 5000
      expect(string_to_price_cents(:usd, "1.000.00")).to eq 100
      expect(string_to_price_cents(:usd, "1.2.3.4")).to eq 123
    end

    it "handles normal prices with a single decimal point" do
      expect(string_to_price_cents(:usd, "9.99")).to eq 999
      expect(string_to_price_cents(:usd, "100.00")).to eq 10_000
      expect(string_to_price_cents(:usd, "0.50")).to eq 50
    end

    it "treats strings without digits as zero" do
      expect(string_to_price_cents(:usd, ".")).to eq 0
      expect(string_to_price_cents(:usd, "..")).to eq 0
      expect(string_to_price_cents(:usd, "")).to eq 0
      expect(string_to_price_cents(:usd, "abc")).to eq 0
    end
  end

  describe "#unit_scaling_factor" do
    it "returns the correct value" do
      expect(unit_scaling_factor("jpy")).to eq(1)
      expect(unit_scaling_factor("usd")).to eq(100)
      expect(unit_scaling_factor("gbp")).to eq(100)
    end
  end

  describe "#formatted_amount_in_currency" do
    it "returns the formatted amount with currency code and no symbol" do
      amount_cents = 1234
      %w(usd cad aud gbp).each do |currency|
        expect(formatted_amount_in_currency(amount_cents, currency)).to eq("#{(amount_cents / 100.0)} #{currency.upcase}")
      end
    end
  end

  describe "#format_just_price_in_cents" do
    it "returns the correct value in USD" do
      expect(format_just_price_in_cents(1299, "usd")).to eq("$12.99")
      expect(format_just_price_in_cents(99, "usd")).to eq("99¢")
    end

    it "returns the correct value in other currencies" do
      expect(format_just_price_in_cents(799, "aud")).to eq("A$7.99")
      expect(format_just_price_in_cents(799, "gbp")).to eq("£7.99")
      expect(format_just_price_in_cents(799, "jpy")).to eq("¥799")
    end
  end

  describe "#formatted_price_with_recurrence" do
    let(:formatted_price) { "$19.99" }
    let(:recurrence) { BasePrice::Recurrence::MONTHLY }
    let(:charge_occurrence_count) { 2 }

    context "with format :short" do
      it "returns the correct value in short format" do
        expect(
          formatted_price_with_recurrence(formatted_price, recurrence, charge_occurrence_count, format: :short)
        ).to eq("$19.99 / month x 2")
      end
    end

    context "with format :long" do
      it "returns the correct value in long format" do
        expect(
          formatted_price_with_recurrence(formatted_price, recurrence, charge_occurrence_count, format: :long)
        ).to eq("$19.99 a month x 2")
      end
    end

    context "when there is no charge_occurrence_count" do
      let(:charge_occurrence_count) { nil }

      it "returns the correct value without count" do
        expect(
          formatted_price_with_recurrence(formatted_price, recurrence, charge_occurrence_count, format: :short)
        ).to eq("$19.99 / month")
      end
    end
  end

  describe "#product_card_formatted_price" do
    let(:price) { 1999 }
    let(:currency_code) { "usd" }
    let(:is_pay_what_you_want) { false }
    let(:recurrence) { nil }
    let(:duration_in_months) { nil }

    it "returns the correct value" do
      expect(
        product_card_formatted_price(price:, currency_code:, is_pay_what_you_want:, recurrence:, duration_in_months:)
      ).to eq("$19.99")
    end

    context "when is_pay_what_you_want is true" do
      let(:is_pay_what_you_want) { true }

      it "adds the plus sign after the price" do
        expect(
          product_card_formatted_price(price:, currency_code:, is_pay_what_you_want:, recurrence:, duration_in_months:)
        ).to eq("$19.99+")
      end

      context "with a recurrence" do
        let(:recurrence) { BasePrice::Recurrence::MONTHLY }

        it "adds recurrence" do
          expect(
            product_card_formatted_price(price:, currency_code:, is_pay_what_you_want:, recurrence:, duration_in_months:)
          ).to eq("$19.99+ a month")
        end

        context "with a duration_in_months" do
          let(:duration_in_months) { 3 }

          it "add duration in months" do
            expect(
              product_card_formatted_price(price:, currency_code:, is_pay_what_you_want:, recurrence:, duration_in_months:)
            ).to eq("$19.99+ a month x 3")
          end
        end
      end
    end
  end
end
