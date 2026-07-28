# frozen_string_literal: true

require "spec_helper"

describe SubscriptionPresentment do
  let(:subscription) { create(:subscription) }

  describe "validations" do
    it "rejects a currency Gumroad does not support" do
      presentment = build(:subscription_presentment, subscription:, presentment_currency: "xyz")

      expect(presentment).not_to be_valid
      expect(presentment.errors[:presentment_currency]).to include("is not a supported currency")
    end

    # A USD row would claim a buyer-currency price the charge path does not honour: a US buyer
    # falls back on :canonical_buyer_currency and no presentment rows are written at all.
    it "rejects the canonical currency, which has nothing to present" do
      presentment = build(:subscription_presentment, subscription:, presentment_currency: "usd")

      expect(presentment).not_to be_valid
      expect(presentment.errors[:presentment_currency]).to include("is the canonical currency, so there is nothing to present")
    end

    it "rejects a currency Stripe cannot charge in minor units" do
      allow(StripeChargeProcessor).to receive(:charge_minor_units_compatible?).with("eur").and_return(false)

      presentment = build(:subscription_presentment, subscription:, presentment_currency: "eur")

      expect(presentment).not_to be_valid
      expect(presentment.errors[:presentment_currency]).to include("cannot be charged in minor units by Stripe")
    end

    it "rejects a zero amount, which would mean billing the buyer nothing every period" do
      presentment = build(:subscription_presentment, subscription:, presentment_price_cents: 0)

      expect(presentment).not_to be_valid
      expect(presentment.errors.attribute_names).to include(:presentment_price_cents)
    end

    it "rejects a non-positive exchange rate, which no conversion could use" do
      expect(build(:subscription_presentment, subscription:, signup_currency_units_per_usd: 0)).not_to be_valid
      expect(build(:subscription_presentment, subscription:, signup_currency_units_per_usd: -1)).not_to be_valid
    end
  end

  # A price change mid-subscription re-fixes the amount, so several rows can exist and the
  # charge path must read the newest one that has taken effect — not the signup row, and not a
  # future-dated one.
  describe "effective dating" do
    it "keeps every fixing and exposes the latest effective one as current" do
      signup = create(:subscription_presentment, subscription:, presentment_price_cents: 999, effective_from: 2.months.ago)
      upgrade = create(:subscription_presentment, subscription:, presentment_price_cents: 1_999, effective_from: 1.day.ago)

      expect(subscription.subscription_presentments).to match_array([signup, upgrade])
      expect(subscription.reload.current_subscription_presentment).to eq(upgrade)
    end

    it "ignores a fixing that has not taken effect yet" do
      current = create(:subscription_presentment, subscription:, presentment_price_cents: 999, effective_from: 1.day.ago)
      create(:subscription_presentment, subscription:, presentment_price_cents: 2_999, effective_from: 1.week.from_now)

      expect(subscription.reload.current_subscription_presentment).to eq(current)
    end
  end

  describe "#usd_cents_when_fixed" do
    it "converts the fixed amount at the rate it was fixed at" do
      presentment = create(:subscription_presentment, subscription:, presentment_currency: "eur", presentment_price_cents: 1_000, signup_currency_units_per_usd: BigDecimal("0.80"))

      expect(presentment.usd_cents_when_fixed).to eq(1_250)
    end

    # Yen amounts are stored in whole yen, not hundredths of a yen. Dividing the stored amount
    # by the rate without accounting for that understates the USD value by a factor of 100,
    # which would make every JPY subscription look like it was worth cents.
    it "handles a single-unit currency without losing a factor of 100" do
      presentment = create(:subscription_presentment, subscription:, presentment_currency: "jpy", presentment_price_cents: 1_500, signup_currency_units_per_usd: BigDecimal("157.0"))

      expect(presentment.usd_cents_when_fixed).to eq(955)
    end
  end

  describe "#usd_drift_cents" do
    let(:presentment) do
      create(:subscription_presentment, subscription:, presentment_currency: "eur", presentment_price_cents: 1_000, signup_currency_units_per_usd: BigDecimal("1.00"))
    end

    it "is zero when the rate has not moved" do
      expect(presentment.usd_drift_cents(BigDecimal("1.00"))).to eq(0)
    end

    it "is positive when the buyer's fixed amount is worth more USD than when it was fixed" do
      # EUR strengthened: 1000 EUR-cents now buys more USD, so Gumroad gains.
      expect(presentment.usd_drift_cents(BigDecimal("0.80"))).to eq(250)
    end

    it "is negative when the buyer's fixed amount is worth less USD than when it was fixed" do
      # EUR weakened: Gumroad absorbs the shortfall, which is the cost of the fixed-amount
      # guarantee and the number worth watching once this ramps.
      expect(presentment.usd_drift_cents(BigDecimal("1.25"))).to eq(-200)
    end

    # nil, not 0: a zero drift is a real and common answer, so returning 0 for "cannot tell"
    # would let an unanswerable row average into a report as a stable one and understate the
    # absorbed drift this record exists to measure.
    it "returns nil rather than zero when the current rate is missing or unusable" do
      expect(presentment.usd_drift_cents(nil)).to be_nil
      expect(presentment.usd_drift_cents(BigDecimal("0"))).to be_nil
      expect(presentment.usd_drift_cents(BigDecimal("-1"))).to be_nil
    end

    it "measures drift on a single-unit currency in USD cents" do
      jpy = create(:subscription_presentment, subscription: create(:subscription), presentment_currency: "jpy", presentment_price_cents: 1_500, signup_currency_units_per_usd: BigDecimal("150.0"))

      # 1,500 yen was worth 1000 USD cents at 150 per dollar and is worth 955 at 157, so Gumroad
      # absorbs 45 cents on every renewal at the weaker rate.
      expect(jpy.usd_drift_cents(BigDecimal("157.0"))).to eq(-45)
    end
  end
end
