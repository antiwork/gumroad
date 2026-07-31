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

    # twd rather than a stubbed currency: Stripe genuinely only accepts New Taiwan dollars in
    # amounts divisible by 100, so this exercises the real gate and would catch a drift in
    # StripeChargeProcessor::AMOUNT_DIVISIBLE_BY_100_CURRENCIES that a stub would hide.
    it "rejects a currency Stripe cannot charge in minor units" do
      presentment = build(:later_charge_presentment, owner: subscription, presentment_currency: "twd")

      expect(presentment).not_to be_valid
      expect(presentment.errors[:presentment_currency]).to include("cannot be charged in minor units by Stripe")
    end

    # Korean won is the one currency where Gumroad's stored minor unit disagrees with Stripe's:
    # Gumroad stores 1/100 won (config/initializers/money.rb) while Stripe charges whole won, so
    # it must never reach a stored fixing at all. Pinned because a KRW row would ALSO read back
    # wrong: KRW is not flagged single_unit in config/currencies.json, so CurrencyHelper would
    # treat a whole-won amount as hundredths and understate the USD figures by a factor of 100.
    # Rejecting the row is what keeps that unreachable, and this asserts the rejection directly.
    it "rejects Korean won, whose stored minor unit disagrees with Stripe's" do
      presentment = build(:later_charge_presentment, owner: subscription, presentment_currency: Currency::KRW)

      expect(presentment).not_to be_valid
      expect(presentment.errors[:presentment_currency]).to include("cannot be charged in minor units by Stripe")
    end

    # Japanese yen is the only currency Gumroad both allows and stores in whole units, so it is
    # the one case where the USD conversion has to scale differently. It is accepted (Stripe also
    # charges whole yen) and CurrencyHelper reads it as single-unit, so both ends agree.
    it "accepts Japanese yen and reads it back in whole units" do
      presentment = create(:later_charge_presentment,
                           owner: subscription,
                           presentment_currency: Currency::JPY,
                           presentment_price_cents: 1_500,
                           signup_currency_units_per_usd: 157)

      expect(presentment).to be_valid
      # 1,500 yen at 157 yen per dollar is 9.55 dollars — 955 USD cents, not 10.
      expect(presentment.usd_cents_when_fixed).to eq(955)
    end

    # A mixed-case row would fail to match a lowercase charge_presentments row in any comparison,
    # so the currency is normalized rather than merely accepted.
    it "stores the currency lowercase however it was given" do
      presentment = create(:later_charge_presentment, owner: subscription, presentment_currency: "EUR")

      expect(presentment.reload.presentment_currency).to eq("eur")
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

    # Rows are the baseline the seller-side drift is measured against, so a re-fixing must add a row
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
      expect(subscription.current_later_charge_presentment).to be_nil
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
      # EUR strengthened: 1000 EUR-cents now buys more USD, so the seller gains.
      expect(presentment.usd_drift_cents(BigDecimal("0.80"))).to eq(250)
    end

    it "is negative when the buyer's fixed amount is worth less USD than when it was fixed" do
      # EUR weakened: the seller absorbs the shortfall, which is the cost of the fixed-amount
      # guarantee and the number worth watching once this ramps.
      expect(presentment.usd_drift_cents(BigDecimal("1.25"))).to eq(-200)
    end

    # nil, not 0: a zero drift is a real and common answer, so returning 0 for "cannot tell"
    # would let an unanswerable row average into a report as a stable one and understate the
    # seller-side drift this record exists to measure.
    it "returns nil rather than zero when the current rate is missing or unusable" do
      expect(presentment.usd_drift_cents(nil)).to be_nil
      expect(presentment.usd_drift_cents(BigDecimal("0"))).to be_nil
      expect(presentment.usd_drift_cents(BigDecimal("-1"))).to be_nil
    end

    # CurrencyHelper#get_rate reads a cache and hands back a String, so a corrupted entry reaches
    # here as garbage. A reporting figure must go unanswerable, not raise out of the report.
    it "returns nil rather than raising on a rate that is not a number at all" do
      expect(presentment.usd_drift_cents("not a rate")).to be_nil
      expect(presentment.usd_drift_cents("NaN")).to be_nil
    end

    it "measures drift on a single-unit currency in USD cents" do
      jpy = create(:later_charge_presentment, owner: create(:subscription), presentment_currency: "jpy", presentment_price_cents: 1_500, signup_currency_units_per_usd: BigDecimal("150.0"))

      # 1,500 yen was worth 1000 USD cents at 150 per dollar and is worth 955 at 157, so Gumroad
      # absorbs 45 cents on every renewal at the weaker rate.
      expect(jpy.usd_drift_cents(BigDecimal("157.0"))).to eq(-45)
    end
  end

  # The figure both the signup write and every later charge anchor on. They call this one method
  # so they cannot end up comparing different bases: Purchase#prepare_for_charge! folds excluded
  # tax and shipping into price_cents, so anchoring on that made a member moving house look
  # exactly like a plan change and dropped the renewal back to US dollars.
  describe ".canonical_price_cents_for" do
    it "is the plan's own price, with tax and shipping taken back out" do
      purchase = build(:purchase, total_transaction_cents: 1_370, price_cents: 1_270,
                                  tax_cents: 250, gumroad_tax_cents: 0, shipping_cents: 120)

      expect(described_class.canonical_price_cents_for(purchase)).to eq(1_000)
    end

    it "does not move when only tax and shipping change" do
      before_move = build(:purchase, total_transaction_cents: 1_000, price_cents: 1_000,
                                     tax_cents: 0, gumroad_tax_cents: 0, shipping_cents: 0)
      after_move = build(:purchase, total_transaction_cents: 1_370, price_cents: 1_270,
                                    tax_cents: 250, gumroad_tax_cents: 0, shipping_cents: 120)

      expect(described_class.canonical_price_cents_for(after_move))
        .to eq(described_class.canonical_price_cents_for(before_move))
    end

    it "moves when the plan price itself changes, which is what must unfix the amount" do
      cheaper = build(:purchase, total_transaction_cents: 1_000, price_cents: 1_000)
      dearer = build(:purchase, total_transaction_cents: 1_500, price_cents: 1_500)

      expect(described_class.canonical_price_cents_for(dearer))
        .not_to eq(described_class.canonical_price_cents_for(cheaper))
    end

    it "excludes a tip, which is agreed once at checkout rather than on every renewal" do
      purchase = build(:purchase, total_transaction_cents: 1_200, price_cents: 1_200)
      allow(purchase).to receive(:tip).and_return(Tip.new(value_usd_cents: 200))

      expect(described_class.canonical_price_cents_for(purchase)).to eq(1_000)
    end
  end

  # The known gap on gumroad-private#1322, pinned so it is a decision rather than a surprise:
  # nothing re-fixes the buyer-currency amount when a plan changes. The writer is the load-bearing
  # half — it declines any owner that already has a fixing, so it can only ever write the first
  # one, and no plan-change path calls it anyway. Adding a re-fixing writer reddens this and forces
  # the class comment documenting the canonical-dollar fallback to be updated with it.
  describe "re-fixing after a plan change" do
    let(:seller) { create(:user) }
    let(:product) { create(:membership_product, user: seller, price_cents: 1_000) }
    let(:subscription) { create(:subscription, link: product, user: create(:user)) }
    let(:original) do
      purchase = build(:membership_purchase, link: product, seller:, subscription:,
                                             is_original_subscription_purchase: true,
                                             price_cents: 1_500, total_transaction_cents: 1_500)
      purchase.save!(validate: false)
      purchase
    end
    let!(:fixing) do
      create(:later_charge_presentment, owner: subscription, presentment_currency: "eur",
                                        presentment_price_cents: 899, canonical_price_cents: 1_000,
                                        effective_from: 30.days.ago)
    end

    it "is not written by the signup writer, which only ever writes an owner's first fixing" do
      charge_presentment = create(:charge_presentment, presentment_currency: "eur", fx_rate: 0.9)
      create(:purchase_presentment, purchase: original, charge_presentment:,
                                    presentment_currency: "eur", presentment_price_cents: 1_349,
                                    presentment_gumroad_tax_cents: 0, presentment_total_cents: 1_349)

      expect { Purchase::FixLaterChargePresentmentService.new(purchase: original).perform }
        .not_to change { subscription.later_charge_presentments.count }

      # The pre-change fixing is still what a charge reads, and it is now stale against the plan,
      # which is what makes the charge path fall back to canonical dollars rather than bill it.
      expect(subscription.reload.current_later_charge_presentment).to eq(fixing)
      expect(described_class.canonical_price_cents_for(original))
        .not_to eq(fixing.canonical_price_cents)
    end
  end
end
