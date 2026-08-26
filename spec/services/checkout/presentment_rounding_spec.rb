# frozen_string_literal: true

describe Checkout::PresentmentRounding do
  # Generous absorption by default so the Gumroad-absorption cap isn't the binding
  # constraint except in the cases that test it on purpose.
  def round(cents, canonical:, currency: Currency::EUR, max_downward_cents: 10_000)
    described_class.round(presentment_total_cents: cents, canonical_total_cents: canonical, currency:, max_downward_cents:)
  end

  describe ".round" do
    it "gives the buyer the seller's .99 ending" do
      # $9.99 converts to €8,53; the seller's ending is 99, so the nearest euro amount
      # ending in 99 is €8,99.
      result = round(8_53, canonical: 9_99)

      expect(result.presentment_total_cents).to eq(8_99)
      expect(result.delta_cents).to eq(46)
      expect(result).to be_rounded
    end

    it "gives the buyer a whole-unit price when the seller priced in whole dollars" do
      # $10 converts to €8,53; the seller's ending is nothing, so the buyer sees €9.
      result = round(8_53, canonical: 10_00)

      expect(result.presentment_total_cents).to eq(9_00)
      expect(result.delta_cents).to eq(47)
    end

    it "mirrors an unusual ending just as literally as a .99 one" do
      # $12.34 → the ending to hit is 34, not a prettier number of our choosing.
      expect(round(10_50, canonical: 12_34).presentment_total_cents).to eq(10_34)
    end

    it "rounds down when the nearer occurrence of the ending is below the amount" do
      result = round(9_10, canonical: 9_99)

      expect(result.presentment_total_cents).to eq(8_99)
      expect(result.delta_cents).to eq(-11)
    end

    it "leaves an amount that already carries the seller's ending exactly where it is" do
      expect(round(8_99, canonical: 9_99).delta_cents).to eq(0)
      expect(round(9_00, canonical: 10_00).delta_cents).to eq(0)
    end

    it "breaks a tie toward the buyer" do
      # €9,00 sits exactly 50 cents from €8,50 and €9,50; charge the lower one.
      expect(round(9_00, canonical: 9_50).presentment_total_cents).to eq(8_50)
    end

    it "quotes the exact converted amount when the ending is too far to reach" do
      # Mirroring 99 onto €1,22 would mean €0,99 (−19%) or €1,99 (+63%). Both are outside
      # the cap for an amount this small, so the buyer sees and pays the exact conversion.
      result = round(1_22, canonical: 9_99)

      expect(result.presentment_total_cents).to eq(1_22)
      expect(result.delta_cents).to eq(0)
    end

    it "mirrors the ending in zero-decimal currencies one place up" do
      # ¥ has no cents, so a .99 ending becomes "one below a round hundred": ¥1,499.
      expect(round(1_483, canonical: 9_99, currency: Currency::JPY).presentment_total_cents).to eq(1_499)
      # And a whole-dollar price becomes a round hundred.
      expect(round(1_483, canonical: 10_00, currency: Currency::JPY).presentment_total_cents).to eq(1_500)
    end

    it "leaves a zero-decimal amount alone when a hundred-unit move is too large for it" do
      expect(round(283, canonical: 9_99, currency: Currency::JPY).delta_cents).to eq(0)
    end

    it "leaves amounts below one major unit alone" do
      expect(round(80, canonical: 9_99).delta_cents).to eq(0)
    end

    it "leaves non-positive amounts alone" do
      expect(round(0, canonical: 9_99).presentment_total_cents).to eq(0)
      expect(round(-100, canonical: 9_99).presentment_total_cents).to eq(-100)
      expect(round(8_53, canonical: 0).presentment_total_cents).to eq(8_53)
    end

    it "never rounds down further than the caller says Gumroad can absorb" do
      expect(round(9_10, canonical: 9_99, max_downward_cents: 11).presentment_total_cents).to eq(8_99)
      # One cent less of headroom and the round-down is refused. The occurrence above is
      # 89 cents away, outside the cap, so the buyer pays the exact converted amount —
      # the shortfall is never taken out of the seller's money.
      expect(round(9_10, canonical: 9_99, max_downward_cents: 10).delta_cents).to eq(0)
    end

    it "still rounds up when Gumroad has nothing to absorb a round-down with" do
      expect(round(8_53, canonical: 9_99, max_downward_cents: 0).presentment_total_cents).to eq(8_99)
    end

    it "charges the exact converted amount and reports it if the rounding itself fails" do
      allow_any_instance_of(described_class).to receive(:candidates).and_raise(StandardError, "boom")
      expect(ErrorNotifier).to receive(:notify).with(instance_of(StandardError), hash_including(:context))

      result = round(8_53, canonical: 9_99)

      expect(result.presentment_total_cents).to eq(8_53)
      expect(result.delta_cents).to eq(0)
    end

    it "can never move an amount by more than Gumroad's flat fee across the whole price range" do
      # The real guarantee this feature rests on: the difference is absorbed out of
      # Gumroad's share, so no move may exceed the fee Gumroad actually collects.
      flat_fee_percent = Purchase::GUMROAD_FLAT_FEE_PER_THOUSAND / 10.0

      [9_99, 10_00, 12_34, 4_50].each do |canonical|
        (1_00..500_00).step(7).each do |cents|
          delta = round(cents, canonical:).delta_cents
          expect(delta.abs * 100).to be <= cents * flat_fee_percent
        end
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

    # The cap has to be a floor under what Gumroad actually collects, and the only thing
    # that makes including tips in its base correct is that Purchase#price_cents is itself
    # tip-inclusive (a tip makes the price "customizable" rather than adding a line beside
    # it), so Purchase's own percentage fee is charged on price + tip too. If that ever
    # changes, a tip-heavy cart could authorise a round-down bigger than Gumroad's share
    # and the difference would come out of the seller's money — so assert the cap against
    # the real fee calculation rather than trusting the comment.
    it "stays within the percentage fee Purchase actually charges on a tip-heavy cart" do
      seller = create(:user, tipping_enabled: true)
      product = create(:product, user: seller, price_cents: 2_00)
      # What the buyer submits for a $2 product with an $8 tip: one tip-inclusive price.
      purchase = build(:purchase, link: product, seller:, price_cents: 10_00)
      purchase.build_tip(value_cents: 8_00, value_usd_cents: 8_00)
      purchase.send(:calculate_fees)

      cap = described_class.absorbable_gumroad_cents(seller:, canonical_price_and_tip_cents: 2_00 + 8_00)

      expect(cap).to be <= purchase.fee_cents
    end

    # Brazilian Stripe Connect accounts pass every buyer-currency eligibility check, so
    # they reach this cap, but Purchase#calculate_fees returns a fee of zero for them.
    # The percentage arithmetic alone would therefore authorise a round-down against a
    # Gumroad share that does not exist, and the orchestrator's clamp would push the
    # difference onto the seller.
    it "is zero for a Brazilian Stripe Connect seller, whom Gumroad charges no fee" do
      seller = create(:user)
      merchant_account = create(:merchant_account_stripe_connect, user: seller, country: "BR")
      product = create(:product, user: seller, price_cents: 10_00)
      purchase = build(:purchase, link: product, seller:, price_cents: 10_00, merchant_account:)
      purchase.send(:calculate_fees)

      expect(purchase.fee_cents).to eq(0)
      expect(
        described_class.absorbable_gumroad_cents(seller:, canonical_price_and_tip_cents: 10_00, merchant_account:)
      ).to eq(0)
    end

    it "still counts the fee for a Stripe Connect seller outside Brazil" do
      seller = create(:user)
      merchant_account = create(:merchant_account_stripe_connect, user: seller, country: "GB")

      expect(
        described_class.absorbable_gumroad_cents(seller:, canonical_price_and_tip_cents: 10_00, merchant_account:)
      ).to eq(1_00)
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

    it "is off when the seller opted out" do
      seller.update!(disable_buyer_currency_rounding: true)

      expect(described_class.enabled_for?(seller)).to eq(false)
    end

    it "stays on when the seller hid local-currency display on product pages" do
      seller.update!(disable_buyer_local_currency: true)

      expect(described_class.enabled_for?(seller)).to eq(true)
    end

    it "is off on fee-waived sales, where Gumroad may have no share to absorb the difference" do
      Feature.activate_user(:waive_gumroad_fee_on_new_sales, seller)

      expect(described_class.enabled_for?(seller)).to eq(false)
    ensure
      Feature.deactivate_user(:waive_gumroad_fee_on_new_sales, seller)
    end
  end
end
