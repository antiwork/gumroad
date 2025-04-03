# frozen_string_literal: true

require "spec_helper"

describe CurrencyHelper do
  describe "#get_rate" do
    it "returns the correct value" do
      expect(get_rate("JPY")).to eq "78.3932"
      expect(get_rate("GBP")).to eq "0.652571"
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
  end

  describe "#min_price_for" do
    it "returns the correct value" do
      expect(min_price_for(:usd)).to eq 99
      expect(min_price_for(:gbp)).to eq 59
    end
  end

  describe "#string_to_price_cents" do
    it "ignores the comma" do
      expect(string_to_price_cents(:usd, "1,200")).to eq 120_000
      expect(string_to_price_cents(:usd, "1,200.99")).to eq 120_099
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
