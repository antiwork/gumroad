# frozen_string_literal: true

require "spec_helper"

describe LaterChargePresentment do
  let(:subscription) { create(:subscription) }

  describe "validations" do
    it "rejects a currency Gumroad does not support" do
      presentment = build(:later_charge_presentment, owner: subscription, presentment_currency: "xyz")

      expect(presentment).not_to be_valid
      expect(presentment.errors[:presentment_currency]).to include("is not a supported currency")
    end

    # A USD row would claim a buyer-currency price the charge path does not honour: a US buyer
    # falls back on :canonical_buyer_currency and no presentment rows are written at all.
    it "rejects the canonical currency, which has nothing to present" do
      presentment = build(:later_charge_presentment, owner: subscription, presentment_currency: "usd")

      expect(presentment).not_to be_valid
      expect(presentment.errors[:presentment_currency]).to include("is the canonical currency, so there is nothing to present")
    end

    it "rejects a currency Stripe cannot charge in minor units" do
      allow(StripeChargeProcessor).to receive(:charge_minor_units_compatible?).with("eur").and_return(false)

      presentment = build(:later_charge_presentment, owner: subscription, presentment_currency: "eur")

      expect(presentment).not_to be_valid
      expect(presentment.errors[:presentment_currency]).to include("cannot be charged in minor units by Stripe")
    end

    it "rejects a zero amount, which would mean billing the buyer nothing every period" do
      presentment = build(:later_charge_presentment, owner: subscription, presentment_price_cents: 0)

      expect(presentment).not_to be_valid
      expect(presentment.errors.attribute_names).to include(:presentment_price_cents)
    end

    it "rejects a non-positive exchange rate, which no conversion could use" do
      expect(build(:later_charge_presentment, owner: subscription, signup_currency_units_per_usd: 0)).not_to be_valid
      expect(build(:later_charge_presentment, owner: subscription, signup_currency_units_per_usd: -1)).not_to be_valid
    end

    # An owner with no later-charge path would make the row inert: it would look like the buyer
    # had a local price while nothing ever read it.
    it "rejects an owner type that has no later charges" do
      presentment = build(:later_charge_presentment, owner: create(:product))

      expect(presentment).not_to be_valid
      expect(presentment.errors[:owner_type]).to include("does not have later charges to present")
    end
  end

  # The four product types in gumroad-private#1322 reduce to three owners, because memberships
  # and installment plans are both Subscriptions internally.
  describe "owners" do
    it "accepts a membership subscription" do
      expect(build(:later_charge_presentment, owner: subscription)).to be_valid
    end

    it "accepts an installment plan, which is a subscription with the flag set" do
      plan = create(:subscription, link: create(:product, :with_installment_plan), is_installment_plan: true)

      expect(plan).to be_is_installment_plan
      expect(build(:later_charge_presentment, owner: plan)).to be_valid
    end

    it "accepts a preorder, charged on release day" do
      expect(build(:later_charge_presentment, owner: create(:preorder))).to be_valid
    end

    # A free deposit purchase, because a paid one talks to Stripe and this example only needs a
    # persisted commission to hang a row off.
    it "accepts a commission, whose balance is charged on completion" do
      deposit = create(:purchase, link: create(:commission_product, price_cents: 0), price_cents: 0, is_commission_deposit_purchase: true)
      commission = create(:commission, deposit_purchase: deposit)

      expect(build(:later_charge_presentment, owner: commission)).to be_valid
    end
  end

  # A price change mid-life re-fixes the amount, so several rows can exist and a charge must read
  # the newest one that has taken effect — not the signup row, and not a future-dated one.
  describe "effective dating" do
    it "keeps every fixing and exposes the latest effective one as current" do
      signup = create(:later_charge_presentment, owner: subscription, presentment_price_cents: 999, effective_from: 2.months.ago)
      upgrade = create(:later_charge_presentment, owner: subscription, presentment_price_cents: 1_999, effective_from: 1.day.ago)

      expect(subscription.later_charge_presentments).to match_array([signup, upgrade])
      expect(subscription.current_later_charge_presentment).to eq(upgrade)
      expect(subscription.fixed_later_charge_price_cents).to eq(1_999)
    end

    it "ignores a fixing that has not taken effect yet" do
      current = create(:later_charge_presentment, owner: subscription, presentment_price_cents: 999, effective_from: 1.day.ago)
      create(:later_charge_presentment, owner: subscription, presentment_price_cents: 2_999, effective_from: 1.week.from_now)

      expect(subscription.current_later_charge_presentment).to eq(current)
    end

    it "does not read another owner's fixing" do
      create(:later_charge_presentment, owner: subscription, presentment_price_cents: 999)
      other = create(:subscription)

      expect(other.current_later_charge_presentment).to be_nil
      expect(other.fixed_later_charge_price_cents).to be_nil
    end

    # Subscriptions and preorders have independent id sequences, so the same id number exists in
    # both tables. Scoping a lookup by id alone would let a subscription read a preorder's amount.
    # Inserted directly because the row is deliberately cross-wired: no valid record could point a
    # Preorder owner_type at a subscription's id.
    it "does not read a fixing belonging to a different owner type with the same id" do
      described_class.insert_all!([{
                                    owner_type: "Preorder",
                                    owner_id: subscription.id,
                                    processor: StripeChargeProcessor.charge_processor_id,
                                    presentment_currency: Currency::EUR,
                                    presentment_price_cents: 4_999,
                                    signup_currency_units_per_usd: BigDecimal("0.89"),
                                    effective_from: 1.day.ago,
                                    created_at: Time.current,
                                    updated_at: Time.current
                                  }])

      expect(subscription.current_later_charge_presentment).to be_nil
      expect(subscription.fixed_later_charge_price_cents).to be_nil
    end

    # Rows are the baseline the absorbed drift is measured against, so a re-fixing must add a row
    # rather than move an existing one.
    it "refuses to be updated in place" do
      presentment = create(:later_charge_presentment, owner: subscription)

      expect { presentment.update!(presentment_price_cents: 1_999) }.to raise_error(ActiveRecord::ReadOnlyRecord)
      expect(presentment.reload.presentment_price_cents).to eq(9_99)
    end
  end

  # The whole point of a fixed amount: the stored figure is authoritative and a rate move must
  # not change what the buyer is billed.
  describe "#fixed_later_charge_price_cents" do
    it "does not move when the exchange rate moves" do
      create(:later_charge_presentment, owner: subscription, presentment_price_cents: 9_99)
      allow_any_instance_of(CurrencyHelper).to receive(:get_rate).and_return(BigDecimal("2.5"))

      expect(subscription.fixed_later_charge_price_cents).to eq(9_99)
    end

    it "is nil when there is no fixing, so the charge falls back to canonical dollars" do
      expect(subscription.fixed_later_charge_price_cents).to be_nil
      expect(subscription.later_charge_presentment_currency).to be_nil
    end
  end

  describe "#usd_cents_when_fixed" do
    it "converts the fixed amount at the rate it was fixed at" do
      presentment = create(:later_charge_presentment, owner: subscription, presentment_currency: "eur", presentment_price_cents: 1_000, signup_currency_units_per_usd: BigDecimal("0.80"))

      expect(presentment.usd_cents_when_fixed).to eq(1_250)
    end

    # Yen amounts are stored in whole yen, not hundredths of a yen. Dividing the stored amount
    # by the rate without accounting for that understates the USD value by a factor of 100,
    # which would make every JPY subscription look like it was worth cents.
    it "handles a single-unit currency without losing a factor of 100" do
      presentment = create(:later_charge_presentment, owner: subscription, presentment_currency: "jpy", presentment_price_cents: 1_500, signup_currency_units_per_usd: BigDecimal("157.0"))

      expect(presentment.usd_cents_when_fixed).to eq(955)
    end
  end

  describe "#usd_drift_cents" do
    let(:presentment) do
      create(:later_charge_presentment, owner: subscription, presentment_currency: "eur", presentment_price_cents: 1_000, signup_currency_units_per_usd: BigDecimal("1.00"))
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
      jpy = create(:later_charge_presentment, owner: create(:subscription), presentment_currency: "jpy", presentment_price_cents: 1_500, signup_currency_units_per_usd: BigDecimal("150.0"))

      # 1,500 yen was worth 1000 USD cents at 150 per dollar and is worth 955 at 157, so Gumroad
      # absorbs 45 cents on every renewal at the weaker rate.
      expect(jpy.usd_drift_cents(BigDecimal("157.0"))).to eq(-45)
    end
  end
end
