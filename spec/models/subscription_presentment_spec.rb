# frozen_string_literal: true

require "spec_helper"

describe SubscriptionPresentment do
  let(:subscription) { create(:subscription) }

  describe "validations" do
    it "requires a subscription, a currency, a positive amount and a positive rate" do
      presentment = SubscriptionPresentment.new

      expect(presentment).not_to be_valid
      expect(presentment.errors.attribute_names).to include(:subscription, :presentment_currency, :presentment_price_cents, :signup_exchange_rate)
    end

    it "is valid for a supported currency" do
      presentment = SubscriptionPresentment.new(subscription:, presentment_currency: "eur", presentment_price_cents: 999, signup_exchange_rate: BigDecimal("0.89"))

      expect(presentment).to be_valid
    end

    it "rejects a currency Gumroad does not support" do
      presentment = SubscriptionPresentment.new(subscription:, presentment_currency: "xyz", presentment_price_cents: 999, signup_exchange_rate: BigDecimal("0.89"))

      expect(presentment).not_to be_valid
      expect(presentment.errors[:presentment_currency]).to include("is not a supported currency")
    end

    it "rejects a zero amount, which would mean billing the buyer nothing every period" do
      presentment = SubscriptionPresentment.new(subscription:, presentment_currency: "eur", presentment_price_cents: 0, signup_exchange_rate: BigDecimal("0.89"))

      expect(presentment).not_to be_valid
      expect(presentment.errors.attribute_names).to include(:presentment_price_cents)
    end

    it "holds at most one record per subscription" do
      create(:subscription_presentment, subscription:)

      expect { create(:subscription_presentment, subscription:) }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe "#fixed_presentment_price_cents" do
    # The point of the whole record: the buyer's amount does not move with the market, so
    # this reader must return the stored amount and never consult a current rate.
    it "returns the amount agreed at signup regardless of any later rate" do
      presentment = create(:subscription_presentment, subscription:, presentment_currency: "eur", presentment_price_cents: 999, signup_exchange_rate: BigDecimal("0.89"))

      expect(presentment.fixed_presentment_price_cents).to eq(999)

      allow(CurrencyHelper).to receive(:get_rate).and_return(BigDecimal("0.95"))

      expect(presentment.fixed_presentment_price_cents).to eq(999)
    end
  end

  describe "#usd_drift_cents" do
    let(:presentment) do
      create(:subscription_presentment, subscription:, presentment_currency: "eur", presentment_price_cents: 1_000, signup_exchange_rate: BigDecimal("1.00"))
    end

    it "is zero when the rate has not moved" do
      expect(presentment.usd_drift_cents(BigDecimal("1.00"))).to eq(0)
    end

    it "is positive when the buyer's fixed amount is worth more USD than at signup" do
      # EUR strengthened: 1000 EUR-cents now buys more USD, so Gumroad gains.
      expect(presentment.usd_drift_cents(BigDecimal("0.80"))).to eq(250)
    end

    it "is negative when the buyer's fixed amount is worth less USD than at signup" do
      # EUR weakened: Gumroad absorbs the shortfall, which is the cost of the fixed-amount
      # guarantee and the number worth watching once this ramps.
      expect(presentment.usd_drift_cents(BigDecimal("1.25"))).to eq(-200)
    end

    it "returns zero rather than dividing by zero on a missing or zero rate" do
      expect(presentment.usd_drift_cents(nil)).to eq(0)
      expect(presentment.usd_drift_cents(BigDecimal("0"))).to eq(0)
    end
  end
end
