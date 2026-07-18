# frozen_string_literal: true

describe Checkout::BuyerCurrencyQuote do
  # Plain price-only cart lines (no tip/tax/shipping), one per product, as the surcharge
  # controller would build them for an untaxed digital cart.
  def line_items_for(*products)
    products.map do |product|
      described_class::LineItem.new(
        permalink: product.unique_permalink,
        product:,
        price_cents: product.price_cents,
        tip_cents: 0,
        seller_tax_cents: 0,
        gumroad_tax_cents: 0,
        shipping_cents: 0
      )
    end
  end

  def canonical_line_items_for(*products)
    products.map { |product| { permalink: product.unique_permalink, total_cents: product.price_cents } }
  end

  let(:seller) { create(:user, disable_buyer_local_currency: false) }
  let(:product) { create(:product, user: seller, price_cents: 10_00, price_currency_type: Currency::USD) }
  let!(:merchant_account) do
    MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id)&.tap do |account|
      account.update!(charge_processor_merchant_id: "acct_gumroad", currency: Currency::USD)
    end || create(:merchant_account, user: nil, charge_processor_merchant_id: "acct_gumroad", currency: Currency::USD)
  end
  let(:stripe_fx_quote) { StripeFxQuote::Quote.new(id: "fxq_test", expires_at: 30.minutes.from_now, fx_rate: BigDecimal("0.8")) }

  before do
    Feature.activate_user(:buyer_local_currency, seller)
    Feature.activate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)
    allow(Stripe).to receive(:api_key).and_return("sk_test_presentment")
    allow_any_instance_of(described_class).to receive(:buyer_currency_for_ip).and_return(Currency::CAD)
    allow(StripeFxQuote).to receive(:create).with(
      to_currency: Currency::USD,
      from_currency: Currency::CAD,
      stripe_account_id: merchant_account.charge_processor_merchant_id
    ).and_return(stripe_fx_quote)
  end

  after do
    Feature.deactivate_user(:buyer_local_currency, seller)
    Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)
  end

  describe ".create" do
    it "creates a signed quote for an eligible single-product checkout" do
      result = described_class.create(line_items: line_items_for(product), canonical_total_cents: 10_00, ip: "24.48.0.1")

      expect(result).to have_attributes(currency: Currency::CAD,
                                        canonical_total_cents: 10_00,
                                        presentment_total_cents: 12_50,
                                        fx_rate: BigDecimal("0.8"),
                                        stripe_fx_quote_id: "fxq_test",
                                        stripe_fx_quote_expires_at: stripe_fx_quote.expires_at)
      expect(result.token).to be_present
    end

    it "returns nil before the internal charging flag is enabled" do
      Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)

      expect(StripeFxQuote).not_to receive(:create)

      result = described_class.create(line_items: line_items_for(product), canonical_total_cents: 10_00, ip: "24.48.0.1")

      expect(result).to be_nil
    end

    it "creates a signed quote in live mode now that the card presentment path has shipped its safety gates" do
      allow(Stripe).to receive(:api_key).and_return("sk_live_presentment")

      result = described_class.create(line_items: line_items_for(product), canonical_total_cents: 10_00, ip: "24.48.0.1")

      expect(result).to have_attributes(currency: Currency::CAD, presentment_total_cents: 12_50)
    end

    it "creates a signed quote locking the cart total for a multi-product single-seller checkout" do
      second_product = create(:product, user: seller, price_cents: 5_00, price_currency_type: Currency::USD)

      result = described_class.create(line_items: line_items_for(product, second_product), canonical_total_cents: 15_00, ip: "24.48.0.1")

      expect(result).to have_attributes(currency: Currency::CAD,
                                        canonical_total_cents: 15_00,
                                        presentment_total_cents: 18_75,
                                        fx_rate: BigDecimal("0.8"),
                                        stripe_fx_quote_id: "fxq_test")
      expect(result.token).to be_present
    end

    it "returns per-line allocations identical to what Charge::PresentmentAllocator persists at charge time" do
      # The reviewer's odd-cent case: $3.34 + $6.67 at 0.8 USD per CAD unit locks CA$12.51,
      # while independent per-line rounding would display CA$4.18 + CA$8.34 = CA$12.52.
      # The quote must return the largest-remainder split [417, 834] — the same amounts the
      # allocator later persists on the purchase presentment rows.
      first_product = create(:product, user: seller, price_cents: 3_34, price_currency_type: Currency::USD)
      second_product = create(:product, user: seller, price_cents: 6_67, price_currency_type: Currency::USD)

      result = described_class.create(line_items: line_items_for(first_product, second_product), canonical_total_cents: 10_01, ip: "24.48.0.1")

      expect(result.presentment_total_cents).to eq(12_51)
      expect(result.line_allocations.map(&:permalink)).to eq([first_product.unique_permalink, second_product.unique_permalink])
      expect(result.line_allocations.map(&:presentment_total_cents)).to eq([4_17, 8_34])
      expect(result.line_allocations.sum(&:presentment_total_cents)).to eq(result.presentment_total_cents)

      charge_time_purchases = [3_34, 6_67].map do |total_transaction_cents|
        instance_double(Purchase,
                        total_transaction_cents:,
                        total_transaction_amount_for_gumroad_cents: 0,
                        tip: nil,
                        tax_cents: 0,
                        gumroad_tax_cents: 0,
                        shipping_cents: 0)
      end
      charge_time_allocations = Charge::PresentmentAllocator.new(
        purchases: charge_time_purchases,
        presentment_total_cents: result.presentment_total_cents,
        presentment_gumroad_amount_cents: 0
      ).allocations

      expect(result.line_allocations.map(&:presentment_total_cents)).to eq(charge_time_allocations.map(&:presentment_total_cents))
      expect(result.line_allocations.map(&:presentment_price_cents)).to eq(charge_time_allocations.map(&:presentment_price_cents))
    end

    it "allocates each line's tip, tax and shipping components so every line reconciles to its own share" do
      second_product = create(:product, user: seller, price_cents: 5_00, price_currency_type: Currency::USD)
      line_items = [
        described_class::LineItem.new(permalink: product.unique_permalink, product:,
                                      price_cents: 10_00, tip_cents: 1_00, seller_tax_cents: 0,
                                      gumroad_tax_cents: 50, shipping_cents: 2_00),
        described_class::LineItem.new(permalink: second_product.unique_permalink, product: second_product,
                                      price_cents: 5_00, tip_cents: 0, seller_tax_cents: 0,
                                      gumroad_tax_cents: 0, shipping_cents: 0),
      ]

      result = described_class.create(line_items:, canonical_total_cents: 18_50, ip: "24.48.0.1")

      expect(result.presentment_total_cents).to eq(23_13)
      expect(result.line_allocations.sum(&:presentment_total_cents)).to eq(23_13)
      result.line_allocations.each do |allocation|
        expect(allocation.presentment_price_cents +
               allocation.presentment_tip_cents +
               allocation.presentment_seller_tax_cents +
               allocation.presentment_gumroad_tax_cents +
               allocation.presentment_shipping_cents).to eq(allocation.presentment_total_cents)
      end
      expect(result.line_allocations.first.presentment_tip_cents).to be_positive
      expect(result.line_allocations.first.presentment_shipping_cents).to be_positive
      expect(result.line_allocations.second).to have_attributes(presentment_tip_cents: 0,
                                                                presentment_seller_tax_cents: 0,
                                                                presentment_gumroad_tax_cents: 0,
                                                                presentment_shipping_cents: 0)
    end

    it "returns nil when the line items do not reconcile to the cart total" do
      # A quote whose lines cannot honestly represent the locked total must not be issued;
      # the cart falls back to canonical USD display and charging.
      expect(StripeFxQuote).not_to receive(:create)

      result = described_class.create(line_items: line_items_for(product), canonical_total_cents: 10_01, ip: "24.48.0.1")

      expect(result).to be_nil
    end

    it "returns nil instead of reporting an error when a line item carries no product" do
      orphan_line = described_class::LineItem.new(
        permalink: "gone", product: nil,
        price_cents: 5_00, tip_cents: 0, seller_tax_cents: 0, gumroad_tax_cents: 0, shipping_cents: 0
      )

      # Without the nil-product guard this path raises NoMethodError, which the blanket
      # fallback rescue swallows — so also assert the error reporter stays quiet.
      expect(ErrorNotifier).not_to receive(:notify)

      result = described_class.create(line_items: line_items_for(product) + [orphan_line], canonical_total_cents: 15_00, ip: "24.48.0.1")

      expect(result).to be_nil
    end

    it "returns nil for carts spanning multiple sellers even when both sellers are flagged in" do
      # One quote locks one PaymentIntent total, but each seller gets their own charge
      # (and intent) — splitting the locked total across intents is not supported.
      other_seller = create(:user, disable_buyer_local_currency: false)
      Feature.activate_user(:buyer_local_currency, other_seller)
      Feature.activate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, other_seller)
      other_seller_product = create(:product, user: other_seller, price_cents: 5_00, price_currency_type: Currency::USD)
      expect(StripeFxQuote).not_to receive(:create)

      result = described_class.create(line_items: line_items_for(product, other_seller_product), canonical_total_cents: 15_00, ip: "24.48.0.1")

      expect(result).to be_nil
    ensure
      Feature.deactivate_user(:buyer_local_currency, other_seller) if other_seller
      Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, other_seller) if other_seller
    end

    it "returns nil when any item in the cart is priced in a non-USD currency" do
      eur_product = create(:product, user: seller, price_cents: 10_00, price_currency_type: Currency::EUR)
      expect(StripeFxQuote).not_to receive(:create)

      result = described_class.create(line_items: line_items_for(product, eur_product), canonical_total_cents: 20_00, ip: "24.48.0.1")

      expect(result).to be_nil
    end

    it "returns nil when any item in the cart offers an installment plan even if the rest are supported" do
      second_product = create(:product, user: seller, price_cents: 5_00, price_currency_type: Currency::USD)
      create(:product_installment_plan, link: second_product, number_of_installments: 3)
      expect(StripeFxQuote).not_to receive(:create)

      result = described_class.create(line_items: line_items_for(product, second_product.reload), canonical_total_cents: 15_00, ip: "24.48.0.1")

      expect(result).to be_nil
    end

    it "returns nil for commission products" do
      # Commissions charge only the deposit now, so a quote locked against the full total
      # could never match the charge amount and would dead-end checkout with a total mismatch.
      seller.update!(created_at: User::MIN_AGE_FOR_SERVICE_PRODUCTS.ago - 1.day)
      commission_product = create(:commission_product, user: seller, price_cents: 10_00)
      expect(StripeFxQuote).not_to receive(:create)

      result = described_class.create(line_items: line_items_for(commission_product), canonical_total_cents: 10_00, ip: "24.48.0.1")

      expect(result).to be_nil
    end

    it "returns nil for products offering installment plans" do
      # Installment intent is not visible at quote time, and an installment checkout
      # charges only the first payment, so these products fall back entirely.
      create(:product_installment_plan, link: product, number_of_installments: 3)
      expect(StripeFxQuote).not_to receive(:create)

      result = described_class.create(line_items: line_items_for(product.reload), canonical_total_cents: 10_00, ip: "24.48.0.1")

      expect(result).to be_nil
    end

    it "returns nil for buyer currencies Gumroad stores in different minor units than Stripe charges" do
      # KRW is stored as 1/100 won (config/initializers/money.rb) but Stripe charges whole won,
      # so quoting it would charge buyers 100x the displayed amount.
      allow_any_instance_of(described_class).to receive(:buyer_currency_for_ip).and_return(Currency::KRW)
      expect(StripeFxQuote).not_to receive(:create)

      result = described_class.create(line_items: line_items_for(product), canonical_total_cents: 10_00, ip: "175.223.10.1")

      expect(result).to be_nil
    end

    it "returns nil for buyer currencies Stripe only charges in amounts divisible by 100" do
      # Stripe rejects TWD amounts that are not evenly divisible by 100, and unrounded
      # FX-quoted amounts cannot guarantee that.
      allow_any_instance_of(described_class).to receive(:buyer_currency_for_ip).and_return(Currency::TWD)
      expect(StripeFxQuote).not_to receive(:create)

      result = described_class.create(line_items: line_items_for(product), canonical_total_cents: 10_00, ip: "1.164.0.1")

      expect(result).to be_nil
    end

    it "quotes whole-unit presentment amounts for zero-decimal buyer currencies" do
      jpy_quote = StripeFxQuote::Quote.new(id: "fxq_jpy", expires_at: 30.minutes.from_now, fx_rate: BigDecimal("0.00694"))
      allow_any_instance_of(described_class).to receive(:buyer_currency_for_ip).and_return(Currency::JPY)
      allow(StripeFxQuote).to receive(:create).with(
        to_currency: Currency::USD,
        from_currency: Currency::JPY,
        stripe_account_id: merchant_account.charge_processor_merchant_id
      ).and_return(jpy_quote)

      result = described_class.create(line_items: line_items_for(product), canonical_total_cents: 10_00, ip: "126.79.0.1")

      # $10.00 at 0.00694 USD per JPY is 1440.92 yen, in whole yen — not 1/100-yen units.
      expect(result).to have_attributes(currency: Currency::JPY, presentment_total_cents: 1441)
    end
  end

  describe ".verify!" do
    it "returns the locked quote when the checkout context matches" do
      result = described_class.create(line_items: line_items_for(product), canonical_total_cents: 10_00, ip: "24.48.0.1")

      verified_quote = described_class.verify!(
        token: result.token,
        seller:,
        merchant_account:,
        currency: Currency::CAD,
        canonical_total_cents: 10_00,
        canonical_line_items: canonical_line_items_for(product)
      )

      expect(verified_quote).to have_attributes(currency: Currency::CAD,
                                                canonical_total_cents: 10_00,
                                                presentment_total_cents: 12_50,
                                                fx_rate: BigDecimal("0.8"),
                                                stripe_fx_quote_id: "fxq_test")
    end

    it "rejects tokens when the canonical total changes" do
      result = described_class.create(line_items: line_items_for(product), canonical_total_cents: 10_00, ip: "24.48.0.1")

      expect do
        described_class.verify!(
          token: result.token,
          seller:,
          merchant_account:,
          currency: Currency::CAD,
          canonical_total_cents: 11_00,
          canonical_line_items: canonical_line_items_for(product)
        )
      end.to raise_error(described_class::InvalidToken, "total mismatch")
    end

    it "rejects tokens when the ordered cart lines change without changing the total" do
      second_product = create(:product, user: seller, price_cents: 5_00, price_currency_type: Currency::USD)
      result = described_class.create(
        line_items: line_items_for(product, second_product),
        canonical_total_cents: 15_00,
        ip: "24.48.0.1"
      )

      expect do
        described_class.verify!(
          token: result.token,
          seller:,
          merchant_account:,
          currency: Currency::CAD,
          canonical_total_cents: 15_00,
          canonical_line_items: [
            { permalink: product.unique_permalink, total_cents: 9_00 },
            { permalink: second_product.unique_permalink, total_cents: 6_00 },
          ]
        )
      end.to raise_error(described_class::InvalidToken, "line items mismatch")
    end

    it "does not bind zero-total cart lines that the charge pipeline completes separately" do
      free_product = create(:product, user: seller, price_cents: 0, price_currency_type: Currency::USD)
      result = described_class.create(
        line_items: line_items_for(product, free_product),
        canonical_total_cents: 10_00,
        ip: "24.48.0.1"
      )

      verified_quote = described_class.verify!(
        token: result.token,
        seller:,
        merchant_account:,
        currency: Currency::CAD,
        canonical_total_cents: 10_00,
        canonical_line_items: canonical_line_items_for(product)
      )

      expect(verified_quote).to have_attributes(currency: Currency::CAD,
                                                canonical_total_cents: 10_00,
                                                presentment_total_cents: 12_50)
    end

    it "rejects expired tokens" do
      result = described_class.create(line_items: line_items_for(product), canonical_total_cents: 10_00, ip: "24.48.0.1")

      travel_to stripe_fx_quote.expires_at + 1.second do
        expect do
          described_class.verify!(
            token: result.token,
            seller:,
            merchant_account:,
            currency: Currency::CAD,
            canonical_total_cents: 10_00,
            canonical_line_items: canonical_line_items_for(product)
          )
        end.to raise_error(described_class::InvalidToken, "expired buyer currency quote")
      end
    end
  end
end
