# frozen_string_literal: true

describe Checkout::PresentmentRounding do
  # Generous by default so the Gumroad-absorption cap isn't the binding constraint except
  # in the cases that test it on purpose.
  def round(cents, currency: Currency::EUR, max_downward_cents: 10_000)
    described_class.round(presentment_total_cents: cents, currency:, max_downward_cents:)
  end

  describe ".round" do
    it "rounds a mid-priced amount to the nearest good-looking ending" do
      result = round(8_53)

      expect(result.presentment_total_cents).to eq(8_49)
      expect(result.delta_cents).to eq(-4)
      expect(result).to be_rounded
    end

    it "rounds up when the nearer target is above the amount" do
      # €8,80 sits 19 cents under €8,99 and 31 cents over €8,49, so the move is upward.
      result = round(8_80)

      expect(result.presentment_total_cents).to eq(8_99)
      expect(result.delta_cents).to eq(19)
    end

    it "leaves an amount that already lands on a target exactly where it is" do
      result = round(8_99)

      expect(result.presentment_total_cents).to eq(8_99)
      expect(result.delta_cents).to eq(0)
      expect(result).not_to be_rounded
    end

    it "uses the finer small-amount targets instead of moving a small price by a fifth" do
      # With only .49/.99 to aim at, this would have gone to €0,99 (−19%) or €1,49 (+20%).
      result = round(1_22)

      expect(result.presentment_total_cents).to eq(1_29)
      expect(result.delta_cents).to eq(7)
    end

    it "targets x.99 in the $25-$100 band" do
      expect(round(31_40).presentment_total_cents).to eq(30_99)
      expect(round(33_10).presentment_total_cents).to eq(32_99)
    end

    it "targets a coarser x4.99 / x9.99 grid above $100" do
      expect(round(142_30).presentment_total_cents).to eq(139_99)
      expect(round(147_80).presentment_total_cents).to eq(149_99)
    end

    it "refuses to round when no target sits inside the band's percentage cap" do
      # 8% of 1.14 is 9 cents; the nearest targets (0.99 and 1.29) are both 15 away.
      result = round(1_14)

      expect(result.presentment_total_cents).to eq(1_14)
      expect(result.delta_cents).to eq(0)
    end

    it "rounds zero-decimal currencies to a round number rather than a .99 ending" do
      result = round(1_483, currency: Currency::JPY)

      expect(result.presentment_total_cents).to eq(1_500)
      expect(result.delta_cents).to eq(17)
    end

    it "picks a coarser grid for larger zero-decimal amounts and a finer one for smaller" do
      expect(round(14_233, currency: Currency::JPY).presentment_total_cents).to eq(14_000)
      expect(round(283, currency: Currency::JPY).presentment_total_cents).to eq(280)
    end

    it "leaves a zero-decimal amount too small for even the finest grid alone" do
      expect(round(9, currency: Currency::JPY).delta_cents).to eq(0)
    end

    it "leaves amounts below one major unit alone" do
      expect(round(80).delta_cents).to eq(0)
    end

    it "leaves non-positive amounts alone" do
      expect(round(0).presentment_total_cents).to eq(0)
      expect(round(-100).presentment_total_cents).to eq(-100)
    end

    it "never rounds down further than the caller says Gumroad can absorb" do
      expect(round(9_12, max_downward_cents: 13).presentment_total_cents).to eq(8_99)
      # One cent less of headroom and the round-down is refused; the next allowed target
      # is above the amount, so the buyer's total goes up instead of down — never into
      # the seller's money.
      expect(round(9_12, max_downward_cents: 12).presentment_total_cents).to eq(9_49)
    end

    it "still rounds up when Gumroad has nothing to absorb a round-down with" do
      expect(round(8_53, max_downward_cents: 0).presentment_total_cents).to eq(8_99)
    end

    it "charges the exact converted amount and reports it if the rounding itself fails" do
      allow_any_instance_of(described_class).to receive(:candidates).and_raise(StandardError, "boom")
      expect(ErrorNotifier).to receive(:notify).with(instance_of(StandardError), hash_including(:context))

      result = round(8_53)

      expect(result.presentment_total_cents).to eq(8_53)
      expect(result.delta_cents).to eq(0)
    end

    it "can never move an amount by more than Gumroad's flat fee across the whole price range" do
      # The real guarantee this feature rests on: the difference is absorbed out of
      # Gumroad's share, so no rounding may exceed the fee Gumroad actually collects.
      flat_fee_percent = Purchase::GUMROAD_FLAT_FEE_PER_THOUSAND / 10.0

      (1_00..500_00).step(7).each do |cents|
        delta = round(cents).delta_cents
        expect(delta.abs * 100).to be <= cents * flat_fee_percent
      end
    end
  end

  describe ".absorbable_gumroad_cents" do
    it "is the flat Gumroad fee on the cart's price and tips" do
      seller = create(:user)

      expect(described_class.absorbable_gumroad_cents(seller:, canonical_price_and_tip_cents: 10_00)).to eq(1_00)
    end

    it "uses the seller's negotiated fee when they have one" do
      seller = create(:user, custom_fee_per_thousand: 50)

      expect(described_class.absorbable_gumroad_cents(seller:, canonical_price_and_tip_cents: 10_00)).to eq(50)
    end

    it "is zero when the seller pays no percentage fee, so a round-down stays off for those sales" do
      seller = create(:user, custom_fee_per_thousand: 0)

      expect(described_class.absorbable_gumroad_cents(seller:, canonical_price_and_tip_cents: 10_00)).to eq(0)
    end
  end

  describe ".enabled_for?" do
    let(:seller) { create(:user, disable_buyer_local_currency: false) }

    before do
      Feature.activate_user(:buyer_local_currency, seller)
      Feature.activate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)
    end

    after do
      Feature.deactivate_user(:buyer_local_currency, seller)
      Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)
    end

    it "is on by default for a seller charging buyers in their own currency" do
      expect(described_class.enabled_for?(seller)).to eq(true)
    end

    it "is off when the seller opted out of rounding" do
      seller.update!(disable_buyer_currency_rounding: true)

      expect(described_class.enabled_for?(seller)).to eq(false)
    end

    it "is off when the seller opted out of buyer-local currency entirely" do
      seller.update!(disable_buyer_local_currency: true)

      expect(described_class.enabled_for?(seller)).to eq(false)
    end

    it "is off on fee-waived sales, where Gumroad may have no share to absorb the difference" do
      Feature.activate_user(:waive_gumroad_fee_on_new_sales, seller)

      expect(described_class.enabled_for?(seller)).to eq(false)
    ensure
      Feature.deactivate_user(:waive_gumroad_fee_on_new_sales, seller)
    end
  end
end
