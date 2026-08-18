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

  # Mirroring the seller's price ending into the buyer's currency is ON by default for
  # sellers charging buyers in their own currency, and it moves the quoted total. That is
  # exercised on purpose in the "price-ending mirroring" examples below; everywhere else in
  # this file the subject is the quote mechanics (FX round trip, allocations, token signing,
  # mismatch cache), so it is opted out to keep the arithmetic in those examples the plain
  # converted amount.
  let(:seller) { create(:user, disable_buyer_local_currency: false, disable_buyer_currency_rounding: true) }
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
      stripe_account_id: merchant_account.charge_processor_merchant_id,
      destination_account_id: nil
    ).and_return(stripe_fx_quote)
  end

  after do
    Feature.deactivate_user(:buyer_local_currency, seller)
    Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)
  end

  describe ".create" do
    it "quotes the requested currency instead of the IP currency" do
      allow(StripeFxQuote).to receive(:create).with(
        to_currency: Currency::USD,
        from_currency: Currency::GBP,
        stripe_account_id: merchant_account.charge_processor_merchant_id,
        destination_account_id: nil
      ).and_return(stripe_fx_quote)

      result = described_class.create(
        line_items: line_items_for(product),
        canonical_total_cents: 10_00,
        ip: "24.48.0.1",
        currency: Currency::GBP
      )

      expect(result).to have_attributes(currency: Currency::GBP, canonical_total_cents: 10_00)
    end

    it "does not quote when the buyer asks for US dollars" do
      result = described_class.create(
        line_items: line_items_for(product),
        canonical_total_cents: 10_00,
        ip: "24.48.0.1",
        currency: Currency::USD
      )

      expect(result).to be_nil
    end

    it "ignores an unknown requested currency and uses the IP currency" do
      result = described_class.create(
        line_items: line_items_for(product),
        canonical_total_cents: 10_00,
        ip: "24.48.0.1",
        currency: "xyz"
      )

      expect(result).to have_attributes(currency: Currency::CAD)
    end

    it "creates a signed quote for an eligible single-product checkout" do
      result = described_class.create(line_items: line_items_for(product), canonical_total_cents: 10_00, ip: "24.48.0.1")

      expect(result).to have_attributes(currency: Currency::CAD,
                                        canonical_total_cents: 10_00,
                                        presentment_total_cents: 12_50,
                                        stripe_fx_quote_expires_at: stripe_fx_quote.expires_at)
      # A created quote covers the cart, which is one prospective charge here; the FX quote it
      # locked lives on that charge.
      expect(result.charges.sole).to have_attributes(canonical_total_cents: 10_00,
                                                     presentment_total_cents: 12_50,
                                                     fx_rate: BigDecimal("0.8"),
                                                     stripe_fx_quote_id: "fxq_test")
      expect(result.token).to be_present
    end

    it "reports the exact rate from the locked quote when the cart is one charge" do
      # A cart of one charge has one Stripe rate, so the browser gets that rate rather than a
      # ratio of totals that were each already rounded to the cent. At $3.34 the ratio would be
      # 1.2514970, and a CA$10.00 tip typed against it would store 799 canonical cents instead
      # of 800.
      product.update!(price_cents: 3_34)

      result = described_class.create(line_items: line_items_for(product), canonical_total_cents: 3_34, ip: "24.48.0.1")

      expect(result.display_rate).to eq(BigDecimal("1.25"))
    end

    it "signs a single-charge quote in the flat shape too, so a rollback can still verify it" do
      # The charge path this token may meet is not necessarily the one that minted it: during a
      # deploy, and for as long as a rollback is possible, it can be read by code that predates
      # per-charge quoting and looks these fields up at the top level, failing the payment if
      # they are missing. Single-seller carts are all of today's buyer-currency traffic, so
      # this shape has to stay readable both ways. Asserted on the payload rather than through
      # `verify!` because it is the OLD verifier, no longer in this codebase, that reads it.
      result = described_class.create(line_items: line_items_for(product), canonical_total_cents: 10_00, ip: "24.48.0.1")

      payload = Rails.application.message_verifier(described_class::TOKEN_PURPOSE).verify(result.token)

      expect(payload).to include("currency" => Currency::CAD,
                                 "seller_id" => seller.id,
                                 "canonical_total_cents" => 10_00,
                                 "presentment_total_cents" => 12_50,
                                 "stripe_fx_quote_id" => "fxq_test")
      expect(payload.fetch("stripe_fx_quote_expires_at")).to eq(stripe_fx_quote.expires_at.iso8601)
      # The same figures are in the per-charge entry the current code reads.
      expect(payload.fetch("charges").sole).to include("seller_id" => seller.id,
                                                       "canonical_total_cents" => 10_00,
                                                       "presentment_total_cents" => 12_50,
                                                       "stripe_fx_quote_id" => "fxq_test")
    end

    context "with price-ending mirroring on (the default for sellers charging in the buyer's currency)" do
      let(:seller) { create(:user, disable_buyer_local_currency: false) }

      it "quotes the seller's own price ending, records the delta, and signs it into the token" do
        # $9.99 at 0.8 USD per CAD unit converts to CA$12.49. The seller's ending is 99, so
        # the buyer is quoted CA$11.99 — the same price ending, in their currency.
        product.update!(price_cents: 9_99)

        result = described_class.create(line_items: line_items_for(product), canonical_total_cents: 9_99, ip: "24.48.0.1")

        expect(result).to have_attributes(currency: Currency::CAD,
                                          canonical_total_cents: 9_99,
                                          presentment_total_cents: 11_99,
                                          rounding_delta_cents: -50)

        # The delta has to survive the token round trip, because the charge books the
        # difference against Gumroad's share from the verified quote rather than
        # recomputing it (a seller flipping the setting mid-checkout must not move money).
        verified = described_class.verify!(token: result.token, seller:, merchant_account:, currency: Currency::CAD, canonical_total_cents: 9_99, canonical_line_items: canonical_line_items_for(product))
        expect(verified.presentment_total_cents).to eq(11_99)
        expect(verified.rounding_delta_cents).to eq(-50)
      end

      it "quotes a whole-unit amount when the seller priced in whole dollars" do
        # $10.00 converts to CA$12.50; the seller's price has no cents, so neither does the
        # buyer's — CA$12.
        result = described_class.create(line_items: line_items_for(product), canonical_total_cents: 10_00, ip: "24.48.0.1")

        expect(result).to have_attributes(presentment_total_cents: 12_00, rounding_delta_cents: -50)
      end

      it "quotes the exact converted amount when the seller opted out" do
        seller.update!(disable_buyer_currency_rounding: true)

        result = described_class.create(line_items: line_items_for(product), canonical_total_cents: 10_00, ip: "24.48.0.1")

        expect(result.presentment_total_cents).to eq(12_50)
        expect(result.rounding_delta_cents).to eq(0)
      end
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
                                        presentment_total_cents: 18_75)
      expect(result.charges.sole).to have_attributes(fx_rate: BigDecimal("0.8"), stripe_fx_quote_id: "fxq_test")
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

    # The charge path exempts a card-saving checkout from the buyer-currency fallback only when
    # every purchase on it is a plain membership. Minting a token for a mixed cart here would
    # not degrade to dollars at the till: the charge refuses a token it cannot honour and raises
    # BuyerCurrencyQuoteInvalid, so the buyer could not complete that checkout at all.
    context "for a cart mixing a membership with a one-off, with the seller in the subscription ramp" do
      before { Feature.activate_user(Checkout::BuyerCurrencyEligibility::SUBSCRIPTION_FEATURE_NAME, seller) }

      let(:membership) { create(:subscription_product, user: seller, price_cents: 10_00, price_currency_type: Currency::USD) }

      it "withholds the quote, so the whole cart is displayed and charged in canonical dollars" do
        expect(StripeFxQuote).not_to receive(:create)

        result = described_class.create(line_items: line_items_for(membership, product),
                                        canonical_total_cents: 20_00, ip: "24.48.0.1")

        expect(result).to be_nil
      end

      it "still quotes a membership bought on its own, which the charge path does honour" do
        result = described_class.create(line_items: line_items_for(membership),
                                        canonical_total_cents: 10_00, ip: "24.48.0.1")

        expect(result).to be_present
        expect(result.currency).to eq(Currency::CAD)
      end
    end

    it "withholds an unsupported platform mandate currency before creating an FX quote" do
      membership = create(:subscription_product, user: seller, price_cents: 10_00, price_currency_type: Currency::USD)
      Feature.activate_user(Checkout::BuyerCurrencyEligibility::SUBSCRIPTION_FEATURE_NAME, seller)
      Feature.activate_user(StripeChargeProcessor::INDIA_CARD_MANDATE_RELIABILITY_FEATURE, seller)
      allow_any_instance_of(described_class).to receive(:buyer_currency_for_ip).and_return(Currency::AUD)
      expect(StripeFxQuote).not_to receive(:create)

      result = described_class.create(
        line_items: line_items_for(membership),
        canonical_total_cents: 10_00,
        ip: "24.48.0.1"
      )

      expect(result).to be_nil
    ensure
      Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::SUBSCRIPTION_FEATURE_NAME, seller)
      Feature.deactivate_user(StripeChargeProcessor::INDIA_CARD_MANDATE_RELIABILITY_FEATURE, seller)
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

    context "with a cart spanning several sellers" do
      let(:other_seller) { create(:user, disable_buyer_local_currency: false, disable_buyer_currency_rounding: true) }
      let(:other_seller_product) { create(:product, user: other_seller, price_cents: 5_00, price_currency_type: Currency::USD) }

      before do
        Feature.activate_user(:buyer_local_currency, other_seller)
        Feature.activate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, other_seller)
      end

      after do
        Feature.deactivate_user(:buyer_local_currency, other_seller)
        Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, other_seller)
      end

      it "locks one quote per seller and reports their sum as the cart total" do
        # Each seller becomes one charge (one PaymentIntent), so each gets its own FX quote:
        # $10 → CA$12.50 and $5 → CA$6.25, and the buyer is shown CA$18.75.
        expect(StripeFxQuote).to receive(:create).twice.and_return(stripe_fx_quote)

        result = described_class.create(line_items: line_items_for(product, other_seller_product), canonical_total_cents: 15_00, ip: "24.48.0.1")

        expect(result).to have_attributes(currency: Currency::CAD,
                                          canonical_total_cents: 15_00,
                                          presentment_total_cents: 18_75)
        expect(result.charges.map(&:canonical_total_cents)).to eq([10_00, 5_00])
        expect(result.charges.map(&:presentment_total_cents)).to eq([12_50, 6_25])
        expect(result.charges.map { _1.seller.id }).to eq([seller.id, other_seller.id])
      end

      it "signs a multi-charge quote with no flat shape, so a rollback cannot read one charge's amount as the cart's" do
        # The flat top-level fields exist only on single-charge tokens (see the flat-shape
        # example above). A multi-charge token gaining them would let code that predates
        # per-charge quoting charge the first charge's amount for every charge in the order —
        # the missing keys are what make such code fail the payment closed instead.
        result = described_class.create(line_items: line_items_for(product, other_seller_product), canonical_total_cents: 15_00, ip: "24.48.0.1")

        payload = Rails.application.message_verifier(described_class::TOKEN_PURPOSE).verify(result.token)

        expect(payload.keys).to match_array(%w[currency charges])
      end

      it "verifies each charge against its OWN locked total, not the cart's" do
        result = described_class.create(line_items: line_items_for(product, other_seller_product), canonical_total_cents: 15_00, ip: "24.48.0.1")

        first = described_class.verify!(token: result.token, seller:, merchant_account:, currency: Currency::CAD,
                                        canonical_total_cents: 10_00, canonical_line_items: canonical_line_items_for(product))
        second = described_class.verify!(token: result.token, seller: other_seller, merchant_account:, currency: Currency::CAD,
                                         canonical_total_cents: 5_00, canonical_line_items: canonical_line_items_for(other_seller_product))

        expect(first.presentment_total_cents).to eq(12_50)
        expect(second.presentment_total_cents).to eq(6_25)
        # Each charge is independently priced, which is what lets the two intents be created
        # and confirmed separately without any cross-charge commit.
        expect(first.canonical_total_cents).to eq(10_00)
        expect(second.canonical_total_cents).to eq(5_00)
      end

      it "rejects a charge that presents the cart total instead of its own" do
        result = described_class.create(line_items: line_items_for(product, other_seller_product), canonical_total_cents: 15_00, ip: "24.48.0.1")

        expect do
          described_class.verify!(token: result.token, seller:, merchant_account:, currency: Currency::CAD,
                                  canonical_total_cents: 15_00, canonical_line_items: canonical_line_items_for(product, other_seller_product))
        end.to raise_error(described_class::InvalidToken, /total mismatch/)
      end

      it "rejects a seller the token covers no charge for" do
        uninvolved_seller = create(:user)
        result = described_class.create(line_items: line_items_for(product, other_seller_product), canonical_total_cents: 15_00, ip: "24.48.0.1")

        expect do
          described_class.verify!(token: result.token, seller: uninvolved_seller, merchant_account:, currency: Currency::CAD,
                                  canonical_total_cents: 10_00, canonical_line_items: canonical_line_items_for(product))
        end.to raise_error(described_class::InvalidToken, /no charge for this seller/)
      end

      it "keeps line allocations in cart order when the cart's sellers interleave" do
        # Charges are built per seller, so the second seller's line is quoted with the first
        # seller's two lines around it. The checkout matches allocations to cart rows by
        # position, so the returned order must be the cart's, not the per-seller grouping's.
        second_product = create(:product, user: seller, price_cents: 3_00, price_currency_type: Currency::USD)
        line_items = line_items_for(product, other_seller_product, second_product)

        result = described_class.create(line_items:, canonical_total_cents: 18_00, ip: "24.48.0.1")

        expect(result.line_allocations.map(&:permalink)).to eq(line_items.map(&:permalink))
        expect(result.line_allocations.sum(&:presentment_total_cents)).to eq(result.presentment_total_cents)
      end

      it "reports the soonest expiry across the cart's quotes" do
        soonest = 5.minutes.from_now
        allow(StripeFxQuote).to receive(:create).and_return(
          StripeFxQuote::Quote.new(id: "fxq_a", expires_at: 30.minutes.from_now, fx_rate: BigDecimal("0.8")),
          StripeFxQuote::Quote.new(id: "fxq_b", expires_at: soonest, fx_rate: BigDecimal("0.8"))
        )

        result = described_class.create(line_items: line_items_for(product, other_seller_product), canonical_total_cents: 15_00, ip: "24.48.0.1")

        expect(result.stripe_fx_quote_expires_at).to be_within(1.second).of(soonest)
      end

      it "reports a rate that returns a typed tip to the buyer unchanged when one seller carries tax" do
        # The browser converts a typed tip through this rate into canonical cents, splits those
        # across the cart by each line's PRICE, then converts each seller's share back at that
        # seller's own rate. Blending the rate over the charge totals would weight it by tax the
        # split never sees, so a buyer typing CA$5.00 would watch the box settle on a different
        # figure. This walks that exact round trip.
        allow(StripeFxQuote).to receive(:create).and_return(
          StripeFxQuote::Quote.new(id: "fxq_a", expires_at: 30.minutes.from_now, fx_rate: BigDecimal("0.8")),
          StripeFxQuote::Quote.new(id: "fxq_b", expires_at: 30.minutes.from_now, fx_rate: BigDecimal("0.5"))
        )
        # Equal prices, and $10 of tax on the second seller's line only.
        taxed_line_items = [
          described_class::LineItem.new(permalink: product.unique_permalink, product:, price_cents: 10_00,
                                        tip_cents: 0, seller_tax_cents: 0, gumroad_tax_cents: 0, shipping_cents: 0),
          described_class::LineItem.new(permalink: other_seller_product.unique_permalink, product: other_seller_product,
                                        price_cents: 10_00, tip_cents: 0, seller_tax_cents: 10_00,
                                        gumroad_tax_cents: 0, shipping_cents: 0),
        ]

        result = described_class.create(line_items: taxed_line_items, canonical_total_cents: 30_00, ip: "24.48.0.1")

        typed_tip_cents = 5_00
        canonical_tip_cents = (BigDecimal(typed_tip_cents) / result.display_rate).round
        # allocateFixedTipCents splits by price and floors each share, so the equal price bases
        # here take half each.
        first_share = canonical_tip_cents / 2
        returned_tip_cents = [[first_share, BigDecimal("0.8")], [canonical_tip_cents - first_share, BigDecimal("0.5")]]
                             .sum { |share, fx_rate| (BigDecimal(share) / fx_rate).round }

        expect(returned_tip_cents).to be_within(1).of(typed_tip_cents)
      end

      it "falls back to canonical USD when one seller's charge cannot be quoted" do
        # One unquotable charge takes the whole cart back to dollars: a cart cannot honestly
        # show a total made of local currency for one seller and dollars for another.
        #
        # The mismatch marker write is stubbed out because both sellers here fall back to the
        # SHARED Gumroad platform merchant account, and recording CAD on it would suppress
        # quoting for every other example in this file. Which account the marker lands on is
        # covered by its own example below.
        allow_any_instance_of(MerchantAccount).to receive(:record_settlement_currency_mismatch!)
        call_count = 0
        allow(StripeFxQuote).to receive(:create) do
          call_count += 1
          raise StripeFxQuote::SettlementCurrencyMismatch, "settles in cad" if call_count > 1

          stripe_fx_quote
        end

        result = described_class.create(line_items: line_items_for(product, other_seller_product), canonical_total_cents: 15_00, ip: "24.48.0.1")

        expect(result).to be_nil
      end

      it "records the settlement mismatch against the account that rejected the quote" do
        # Per-account, per-currency: a mismatch learned for one seller's account must not
        # suppress quoting for another seller's. Asserted on the receiver rather than on
        # persisted state, because actually writing the marker to the SHARED Gumroad platform
        # account (which every seller here falls back to) would suppress quoting for the rest
        # of this file.
        other_seller_account = create(:merchant_account_stripe_connect, user: other_seller, currency: Currency::USD)
        other_seller.update!(check_merchant_account_is_linked: true)
        allow(StripeFxQuote).to receive(:create)
          .with(to_currency: Currency::USD, from_currency: Currency::CAD, stripe_account_id: merchant_account.charge_processor_merchant_id, destination_account_id: nil)
          .and_return(stripe_fx_quote)
        allow(StripeFxQuote).to receive(:create)
          .with(to_currency: Currency::USD, from_currency: Currency::CAD, stripe_account_id: other_seller_account.charge_processor_merchant_id, destination_account_id: nil)
          .and_raise(StripeFxQuote::SettlementCurrencyMismatch, "settles in cad")
        expect_any_instance_of(MerchantAccount).to receive(:record_settlement_currency_mismatch!).with(Currency::CAD) do |account|
          expect(account.id).to eq(other_seller_account.id)
        end

        result = described_class.create(line_items: line_items_for(product, other_seller_product), canonical_total_cents: 15_00, ip: "24.48.0.1")

        expect(result).to be_nil
      end

      it "quotes a cart holding as many sellers as the lane will quote" do
        # One FX round trip per seller, right at the limit.
        extra_sellers = Array.new(described_class::MAX_QUOTED_CHARGES - 2) do
          create(:user, disable_buyer_local_currency: false, disable_buyer_currency_rounding: true).tap do |extra_seller|
            Feature.activate_user(:buyer_local_currency, extra_seller)
            Feature.activate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, extra_seller)
          end
        end
        extra_products = extra_sellers.map { create(:product, user: _1, price_cents: 1_00, price_currency_type: Currency::USD) }
        products = [product, other_seller_product, *extra_products]
        expect(StripeFxQuote).to receive(:create).exactly(described_class::MAX_QUOTED_CHARGES).times.and_return(stripe_fx_quote)

        result = described_class.create(line_items: line_items_for(*products),
                                        canonical_total_cents: products.sum(&:price_cents),
                                        ip: "24.48.0.1")

        expect(result.charges.length).to eq(described_class::MAX_QUOTED_CHARGES)
      ensure
        extra_sellers&.each do |extra_seller|
          Feature.deactivate_user(:buyer_local_currency, extra_seller)
          Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, extra_seller)
        end
      end

      it "falls back to canonical USD without asking Stripe when the cart holds more sellers than the lane quotes" do
        # Each seller costs one sequential FX round trip on the request the buyer is waiting on,
        # so a cart wider than the limit takes dollars instead of making them wait through the
        # whole chain. No quote is minted at all: the limit is checked before the first call.
        extra_sellers = Array.new(described_class::MAX_QUOTED_CHARGES - 1) do
          create(:user, disable_buyer_local_currency: false, disable_buyer_currency_rounding: true).tap do |extra_seller|
            Feature.activate_user(:buyer_local_currency, extra_seller)
            Feature.activate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, extra_seller)
          end
        end
        extra_products = extra_sellers.map { create(:product, user: _1, price_cents: 1_00, price_currency_type: Currency::USD) }
        products = [product, other_seller_product, *extra_products]
        expect(products.map(&:user_id).uniq.length).to be > described_class::MAX_QUOTED_CHARGES
        expect(StripeFxQuote).not_to receive(:create)

        result = described_class.create(line_items: line_items_for(*products),
                                        canonical_total_cents: products.sum(&:price_cents),
                                        ip: "24.48.0.1")

        expect(result).to be_nil
      ensure
        extra_sellers&.each do |extra_seller|
          Feature.deactivate_user(:buyer_local_currency, extra_seller)
          Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, extra_seller)
        end
      end
    end

    it "quotes a cart priced in a non-USD currency that is not the buyer's own" do
      # The seller pricing in euros says nothing about what a Canadian buyer should see:
      # the cart total reaching this service is canonical USD either way, so it converts
      # into the buyer's currency exactly as a USD-priced cart does.
      eur_product = create(:product, user: seller, price_cents: 10_00, price_currency_type: Currency::EUR)

      result = described_class.create(line_items: line_items_for(product, eur_product), canonical_total_cents: 20_00, ip: "24.48.0.1")

      expect(result).to have_attributes(currency: Currency::CAD, presentment_total_cents: 25_00)
    end

    it "withholds the quote when a tip rides on a non-USD listing, because the two tip splits disagree" do
      # REGRESSION for rmarescu's review finding on #6350.
      #
      # The tip is allocated twice in different units: the surcharge request that mints the
      # quote splits it over each line's canonical USD price, while the submitted order
      # splits it over each line's listed price and the server converts that back through
      # get_usd_cents. For a USD listing the two agree; for any other listing currency they
      # sit on either side of a division by the same rate and disagree by a cent, so verify!
      # rejects the token and the buyer's payment fails. Until both sides split from the same
      # figures, such a cart must fall back to the canonical USD checkout rather than be
      # quoted into a payment that cannot complete.
      eur_product = create(:product, user: seller, price_cents: 10_00, price_currency_type: Currency::EUR)
      tipped_eur_line = described_class::LineItem.new(
        permalink: eur_product.unique_permalink, product: eur_product,
        price_cents: 10_00, tip_cents: 1_00, seller_tax_cents: 0,
        gumroad_tax_cents: 0, shipping_cents: 0
      )

      expect(described_class.create(line_items: [tipped_eur_line], canonical_total_cents: 11_00, ip: "24.48.0.1")).to be_nil
    end

    it "still quotes a non-USD listing when there is no tip on it" do
      # The gate above must be scoped to the tip, not to the listing currency — withholding
      # every non-USD cart would revert the whole point of this PR.
      eur_product = create(:product, user: seller, price_cents: 10_00, price_currency_type: Currency::EUR)

      result = described_class.create(line_items: line_items_for(eur_product), canonical_total_cents: 10_00, ip: "24.48.0.1")

      expect(result).to have_attributes(currency: Currency::CAD, presentment_total_cents: 12_50)
    end

    it "still quotes a tip that rides on a USD listing" do
      # A tip is only unsafe in combination with a non-USD listing. USD-listed tipping is the
      # behaviour that already ships and must not regress.
      tipped_usd_line = described_class::LineItem.new(
        permalink: product.unique_permalink, product:,
        price_cents: 10_00, tip_cents: 1_00, seller_tax_cents: 0,
        gumroad_tax_cents: 0, shipping_cents: 0
      )

      result = described_class.create(line_items: [tipped_usd_line], canonical_total_cents: 11_00, ip: "24.48.0.1")

      expect(result).to have_attributes(currency: Currency::CAD, presentment_total_cents: 13_75)
    end

    it "quotes a non-USD listing that carries shipping once surcharge and charge convert each rate term the same way" do
      # Shipping used to diverge (surcharge convert(sum) vs purchase sum(convert)) and the
      # quote was withheld. CustomerSurchargeController now passes the product currency into
      # calculate_shipping_rate, matching Purchase#calculate_shipping, so shipping alone is
      # safe to quote. Tip remains gated separately.
      eur_product = create(:product, user: seller, price_cents: 10_00, price_currency_type: Currency::EUR)
      shipped_eur_line = described_class::LineItem.new(
        permalink: eur_product.unique_permalink, product: eur_product,
        price_cents: 10_00, tip_cents: 0, seller_tax_cents: 0,
        gumroad_tax_cents: 0, shipping_cents: 5_00
      )

      result = described_class.create(line_items: [shipped_eur_line], canonical_total_cents: 15_00, ip: "24.48.0.1")

      expect(result).to have_attributes(currency: Currency::CAD, presentment_total_cents: 18_75)
    end

    it "still quotes shipping that rides on a USD listing" do
      # USD-listed shipping has nothing to convert, so both sides already agreed. Keep this
      # as a regression against a tip-only gate accidentally swallowing USD shipping too.
      shipped_usd_line = described_class::LineItem.new(
        permalink: product.unique_permalink, product:,
        price_cents: 10_00, tip_cents: 0, seller_tax_cents: 0,
        gumroad_tax_cents: 0, shipping_cents: 5_00
      )

      result = described_class.create(line_items: [shipped_usd_line], canonical_total_cents: 15_00, ip: "24.48.0.1")

      expect(result).to have_attributes(currency: Currency::CAD, presentment_total_cents: 18_75)
    end

    it "quotes a mixed cart when only shipping (not tip) rides on a non-USD listing" do
      # Shipping conversion now matches on both sides, so one non-USD shipped line no longer
      # forces the whole cart back to USD.
      eur_product = create(:product, user: seller, price_cents: 10_00, price_currency_type: Currency::EUR)
      lines = [
        described_class::LineItem.new(permalink: product.unique_permalink, product:,
                                      price_cents: 10_00, tip_cents: 0, seller_tax_cents: 0,
                                      gumroad_tax_cents: 0, shipping_cents: 0),
        described_class::LineItem.new(permalink: eur_product.unique_permalink, product: eur_product,
                                      price_cents: 10_00, tip_cents: 0, seller_tax_cents: 0,
                                      gumroad_tax_cents: 0, shipping_cents: 5_00),
      ]

      result = described_class.create(line_items: lines, canonical_total_cents: 25_00, ip: "24.48.0.1")

      expect(result).to have_attributes(currency: Currency::CAD, presentment_total_cents: 31_25)
    end

    it "withholds the quote for the whole cart when only one line pairs a tip with a non-USD listing" do
      # A mixed cart is not a special case, it is the same defect: one offending line is
      # enough, because the quote locks a single total for the entire cart.
      eur_product = create(:product, user: seller, price_cents: 10_00, price_currency_type: Currency::EUR)
      lines = [
        described_class::LineItem.new(permalink: product.unique_permalink, product:,
                                      price_cents: 10_00, tip_cents: 0, seller_tax_cents: 0,
                                      gumroad_tax_cents: 0, shipping_cents: 0),
        described_class::LineItem.new(permalink: eur_product.unique_permalink, product: eur_product,
                                      price_cents: 10_00, tip_cents: 1_00, seller_tax_cents: 0,
                                      gumroad_tax_cents: 0, shipping_cents: 0),
      ]

      expect(described_class.create(line_items: lines, canonical_total_cents: 21_00, ip: "24.48.0.1")).to be_nil
    end

    it "withholds the quote when the tip landed on a USD line but the cart carries a non-USD listing" do
      # The surcharge request and the submitted order split the tip with the same
      # largest-remainder code but over different price bases (canonical USD vs listed),
      # so a cent that lands on the USD line at quote time can land on the EUR line at
      # submit. The gate must therefore key off the cart (any tip + any non-USD listing),
      # not off which line the quote-time split happened to put the tip on: a token minted
      # for this cart would fail per-line verification whenever the submit-time split
      # moves the cent.
      eur_product = create(:product, user: seller, price_cents: 10_00, price_currency_type: Currency::EUR)
      lines = [
        described_class::LineItem.new(permalink: product.unique_permalink, product:,
                                      price_cents: 10_00, tip_cents: 1_00, seller_tax_cents: 0,
                                      gumroad_tax_cents: 0, shipping_cents: 0),
        described_class::LineItem.new(permalink: eur_product.unique_permalink, product: eur_product,
                                      price_cents: 10_00, tip_cents: 0, seller_tax_cents: 0,
                                      gumroad_tax_cents: 0, shipping_cents: 0),
      ]

      expect(described_class.create(line_items: lines, canonical_total_cents: 21_00, ip: "24.48.0.1")).to be_nil
    end

    it "treats a non-USD line's submitted price as already-canonical USD, matching the purchase total" do
      # LOAD-BEARING UNITS INVARIANT. The browser converts before it posts — getProducts in
      # pages/Checkout/Show.tsx sends `price: convertToUSD(item, price)` — so the surcharge
      # endpoint's `price` is USD cents for every cart, whatever currency the seller priced in.
      # LineItem.from_surcharge must therefore pass it through untouched.
      #
      # A reviewer read the field as product-priced and proposed converting it here. That is a
      # DOUBLE conversion, and it manufactures exactly the charge-time mismatch it was meant to
      # prevent: a €10.00 product posts 1233 USD cents, and converting again yields 1520 against
      # a purchase whose total_transaction_cents is 1233 — every such checkout would fail
      # verification. This example pins the two figures to each other so the mistake reddens.
      eur_product = create(:product, user: seller, price_cents: 10_00, price_currency_type: Currency::EUR)

      purchase = build(:purchase, link: eur_product, seller:, purchase_state: "in_progress")
      purchase.set_price_and_rate
      posted_price_cents = purchase.total_transaction_cents
      expect(posted_price_cents).not_to eq(eur_product.price_cents), "expected the purchase total to be converted USD, not the listed EUR cents"

      tax_result = double(price_cents: posted_price_cents, tax_cents: 0, zip_tax_rate: nil, used_taxjar: false, gumroad_is_mpf: false)
      line_item = described_class::LineItem.from_surcharge(
        permalink: eur_product.unique_permalink,
        product: eur_product,
        tax_result:,
        tip_cents: 0,
        shipping_usd_cents: 0
      )

      expect(line_item.canonical_total_cents).to eq(posted_price_cents)

      result = described_class.create(line_items: [line_item], canonical_total_cents: posted_price_cents, ip: "24.48.0.1")
      expect do
        described_class.verify!(
          token: result.token,
          seller:,
          merchant_account:,
          currency: Currency::CAD,
          canonical_total_cents: posted_price_cents,
          canonical_line_items: [{ permalink: eur_product.unique_permalink, total_cents: posted_price_cents }]
        )
      end.not_to raise_error
    end

    it "returns nil when an item is already priced in the buyer's own currency" do
      # Converting a listed CAD price to USD and back through an FX quote would charge a
      # Canadian buyer something a cent or two off the CAD price on the page. That cart is
      # charged its listed price directly instead, so it must not be quoted here.
      cad_product = create(:product, user: seller, price_cents: 10_00, price_currency_type: Currency::CAD)
      expect(StripeFxQuote).not_to receive(:create)

      result = described_class.create(line_items: line_items_for(cad_product), canonical_total_cents: 10_00, ip: "24.48.0.1")

      expect(result).to be_nil
    end

    it "quotes a mixed cart when only one item is priced in the buyer's currency" do
      cad_product = create(:product, user: seller, price_cents: 10_00, price_currency_type: Currency::CAD)
      usd_canonical = 12_50
      cad_line = described_class::LineItem.new(
        permalink: cad_product.unique_permalink,
        product: cad_product,
        price_cents: usd_canonical,
        tip_cents: 0,
        seller_tax_cents: 0,
        gumroad_tax_cents: 0,
        shipping_cents: 0,
        listed_currency_rate: "0.8"
      )
      line_items = line_items_for(product) + [cad_line]
      canonical_total = product.price_cents + usd_canonical

      expect(described_class.buyer_currency_listing_quotable?(line_items:, buyer_currency: Currency::CAD)).to be(true)

      result = described_class.create(line_items:, canonical_total_cents: canonical_total, ip: "24.48.0.1")

      expect(result).to have_attributes(currency: Currency::CAD, canonical_total_cents: canonical_total)
      cad_allocation = result.line_allocations.find { _1.permalink == cad_product.unique_permalink }
      expect(cad_allocation.presentment_price_cents).to eq(10_00)
      expect(StripeFxQuote).to have_received(:create)
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

    context "when the later-charge ramp is on" do
      before { Feature.activate_user(Checkout::BuyerCurrencyEligibility::SUBSCRIPTION_FEATURE_NAME, seller) }

      after { Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::SUBSCRIPTION_FEATURE_NAME, seller) }

      it "signs the first installment separately from the full agreement" do
        create(:product_installment_plan, link: product, number_of_installments: 3)
        line_item = described_class::LineItem.new(
          permalink: product.unique_permalink,
          product: product.reload,
          price_cents: 10_00,
          tip_cents: 0,
          seller_tax_cents: 0,
          gumroad_tax_cents: 0,
          shipping_cents: 0,
          charge_price_cents: 3_34,
          charge_tip_cents: 0,
          charge_seller_tax_cents: 0,
          charge_gumroad_tax_cents: 0,
          charge_shipping_cents: 0,
          later_charge_kind: "installment",
          later_charge_price_cents: 3_33
        )

        result = described_class.create(line_items: [line_item], canonical_total_cents: 10_00, ip: "24.48.0.1")
        verified = described_class.verify!(
          token: result.token,
          seller:,
          merchant_account:,
          currency: Currency::CAD,
          canonical_total_cents: 3_34,
          canonical_line_items: [{ permalink: product.unique_permalink, total_cents: 3_34 }],
          later_charge_canonical_line_items: [{ permalink: product.unique_permalink, canonical_price_cents: 3_33 }]
        )

        expect(result).to have_attributes(
          presentment_total_cents: 12_50,
          charge_presentment_total_cents: 4_18,
          future_installments_presentment_total_cents: 8_32
        )
        expect(verified).to have_attributes(canonical_total_cents: 3_34, presentment_total_cents: 4_18, rounding_delta_cents: 0)
      end

      it "signs a commission deposit separately from its full agreement" do
        seller.update!(created_at: User::MIN_AGE_FOR_SERVICE_PRODUCTS.ago - 1.day)
        commission_product = create(:commission_product, user: seller, price_cents: 10_00)
        line_item = described_class::LineItem.new(
          permalink: commission_product.unique_permalink,
          product: commission_product,
          price_cents: 10_00,
          tip_cents: 0,
          seller_tax_cents: 0,
          gumroad_tax_cents: 0,
          shipping_cents: 0,
          charge_price_cents: 5_00,
          charge_tip_cents: 0,
          charge_seller_tax_cents: 0,
          charge_gumroad_tax_cents: 0,
          charge_shipping_cents: 0,
          later_charge_kind: "commission",
          later_charge_price_cents: 5_00
        )

        result = described_class.create(line_items: [line_item], canonical_total_cents: 10_00, ip: "24.48.0.1")

        expect(result).to have_attributes(presentment_total_cents: 12_50, charge_presentment_total_cents: 6_25)
      end

      it "signs a preorder agreement without an initial charge" do
        product.update!(is_in_preorder_state: true)
        line_item = described_class::LineItem.new(
          permalink: product.unique_permalink,
          product:,
          price_cents: 10_00,
          tip_cents: 0,
          seller_tax_cents: 0,
          gumroad_tax_cents: 0,
          shipping_cents: 0,
          charge_price_cents: 0,
          charge_tip_cents: 0,
          charge_seller_tax_cents: 0,
          charge_gumroad_tax_cents: 0,
          charge_shipping_cents: 0,
          later_charge_kind: "preorder",
          later_charge_price_cents: 10_00
        )

        result = described_class.create(line_items: [line_item], canonical_total_cents: 10_00, ip: "24.48.0.1")

        expect(result).to have_attributes(presentment_total_cents: 12_50, charge_presentment_total_cents: 0)
      end

      it "keeps partial-charge products to a single line" do
        create(:product_installment_plan, link: product, number_of_installments: 3)
        installment = described_class::LineItem.new(
          **line_items_for(product.reload).sole.to_h,
          charge_price_cents: 3_34,
          later_charge_kind: "installment",
          later_charge_price_cents: 3_33
        )
        second_product = create(:product, user: seller, price_cents: 5_00)

        expect(
          described_class.create(
            line_items: [installment, line_items_for(second_product).sole],
            canonical_total_cents: 15_00,
            ip: "24.48.0.1"
          )
        ).to be_nil
      end
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
        stripe_account_id: merchant_account.charge_processor_merchant_id,
        destination_account_id: nil
      ).and_return(jpy_quote)

      result = described_class.create(line_items: line_items_for(product), canonical_total_cents: 10_00, ip: "126.79.0.1")

      # $10.00 at 0.00694 USD per JPY is 1440.92 yen, in whole yen — not 1/100-yen units.
      expect(result).to have_attributes(currency: Currency::JPY, presentment_total_cents: 1441)
    end

    it "falls back to nil without notifying Sentry when the account settles in a non-USD currency" do
      # Production case: Stripe rejects the quote request for accounts with multi-currency
      # settlement ("The FX Quote's to_currency ... must match the payment intent's
      # settlement currency"). This is expected, not a defect — no error notification.
      allow(StripeFxQuote).to receive(:create).and_raise(
        StripeFxQuote::SettlementCurrencyMismatch, "FX quote settles in cad, expected usd"
      )
      expect(ErrorNotifier).not_to receive(:notify)

      result = described_class.create(line_items: line_items_for(product), canonical_total_cents: 10_00, ip: "24.48.0.1")

      expect(result).to be_nil
    end

    it "records the mismatch per currency on a Gumroad-managed account, leaving other currencies quoting" do
      # The shared platform account can genuinely settle one currency in itself (enabling
      # iDEAL/SEPA made EUR settle in EUR on 2026-07-22, gumroad-private#933), so the
      # per-currency marker must be recorded there too — the earlier blanket "never record
      # on managed accounts" guard (#6117) left the mismatching currency failing closed at
      # PaymentIntent create instead of falling back to USD. Only the observed currency is
      # marked; the legacy blanket marker is never written.
      allow(StripeFxQuote).to receive(:create).and_raise(
        StripeFxQuote::SettlementCurrencyMismatch, "FX quote settles in cad, expected usd"
      )

      described_class.create(line_items: line_items_for(product), canonical_total_cents: 10_00, ip: "24.48.0.1")

      expect(merchant_account.reload.settlement_currency_mismatch_active?(Currency::CAD)).to be(true)
      expect(merchant_account.settlement_currency_mismatch_active?("eur")).to be(false)
      expect(merchant_account.settlement_currency_mismatch_noticed_at).to be_nil
    end

    it "records the mismatch on a seller-owned connected account" do
      seller.update!(check_merchant_account_is_linked: true)
      seller_merchant_account = create(:merchant_account_stripe_connect, user: seller)
      allow(StripeFxQuote).to receive(:create).with(
        to_currency: Currency::USD,
        from_currency: Currency::CAD,
        stripe_account_id: seller_merchant_account.charge_processor_merchant_id,
        destination_account_id: nil
      ).and_raise(StripeFxQuote::SettlementCurrencyMismatch, "FX quote settles in cad, expected usd")

      expect do
        described_class.create(line_items: line_items_for(product), canonical_total_cents: 10_00, ip: "24.48.0.1")
      end.to change { seller_merchant_account.reload.settlement_currency_mismatch_active?(Currency::CAD) }.from(false).to(true)
    end

    it "skips the FX-quote round trip entirely while a recorded mismatch is fresh for the buyer's currency" do
      seller.update!(check_merchant_account_is_linked: true)
      seller_merchant_account = create(:merchant_account_stripe_connect, user: seller)
      seller_merchant_account.record_settlement_currency_mismatch!(Currency::CAD)
      expect(StripeFxQuote).not_to receive(:create)

      result = described_class.create(line_items: line_items_for(product), canonical_total_cents: 10_00, ip: "24.48.0.1")

      expect(result).to be_nil
    end

    it "still honors a fresh legacy blanket marker on a seller-connected account" do
      # Markers written before the per-currency map existed must keep their USD fallback
      # until they expire (the write path only produces the map now).
      seller.update!(check_merchant_account_is_linked: true)
      seller_merchant_account = create(:merchant_account_stripe_connect, user: seller)
      seller_merchant_account.update!(settlement_currency_mismatch_noticed_at: Time.current.iso8601)
      expect(StripeFxQuote).not_to receive(:create)

      result = described_class.create(line_items: line_items_for(product), canonical_total_cents: 10_00, ip: "24.48.0.1")

      expect(result).to be_nil
    end

    it "still falls back to nil when recording the mismatch itself fails" do
      # The persistence of the learned marker is best-effort bookkeeping; a failure there
      # must not turn an expected fallback into a checkout error.
      allow(StripeFxQuote).to receive(:create).and_raise(
        StripeFxQuote::SettlementCurrencyMismatch, "FX quote settles in cad, expected usd"
      )
      allow_any_instance_of(MerchantAccount).to receive(:record_settlement_currency_mismatch!).and_raise("db hiccup")
      expect(ErrorNotifier).not_to receive(:notify)

      result = described_class.create(line_items: line_items_for(product), canonical_total_cents: 10_00, ip: "24.48.0.1")

      expect(result).to be_nil
    end

    context "destination charges" do
      # A Gumroad-managed Stripe Custom account: owned by the seller, but Stripe creates
      # the PaymentIntent on the platform account and transfers to this one afterwards.
      let!(:seller_merchant_account) do
        seller.update!(check_merchant_account_is_linked: true)
        create(:merchant_account, user: seller, charge_processor_merchant_id: "acct_seller_custom", currency: Currency::USD)
      end

      it "returns nil while the destination-charge ramp flag is off" do
        expect(StripeFxQuote).not_to receive(:create)

        expect(described_class.create(line_items: line_items_for(product), canonical_total_cents: 10_00, ip: "24.48.0.1")).to be_nil
      end

      context "with the destination-charge ramp flag on" do
        before { Feature.activate_user(Checkout::BuyerCurrencyEligibility::DESTINATION_CHARGE_FEATURE_NAME, seller) }
        after { Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::DESTINATION_CHARGE_FEATURE_NAME, seller) }

        it "mints the quote on the platform account, not the seller's" do
          # The intent for a destination charge is created on the platform account, and a
          # quote is only honoured in the account context that minted it.
          expect(StripeFxQuote).to receive(:create).with(
            to_currency: Currency::USD,
            from_currency: Currency::CAD,
            stripe_account_id: merchant_account.charge_processor_merchant_id,
            # Stripe refuses a quote whose destination does not match the intent's
            # transfer_data[destination], so the seller's account has to be named here even
            # though the quote is minted on the platform account.
            destination_account_id: "acct_seller_custom"
          ).and_return(stripe_fx_quote)

          result = described_class.create(line_items: line_items_for(product), canonical_total_cents: 10_00, ip: "24.48.0.1")

          expect(result).to have_attributes(currency: Currency::CAD)
          # The quote id now lives on the per-charge record rather than the cart-level result,
          # since a multi-seller cart locks one FX quote per prospective charge.
          expect(result.charges.sole).to have_attributes(stripe_fx_quote_id: "fxq_test")
        end

        it "records a settlement mismatch on the platform account, which is the one that rejected it" do
          allow(StripeFxQuote).to receive(:create).and_raise(
            StripeFxQuote::SettlementCurrencyMismatch, "FX quote settles in cad, expected usd"
          )

          described_class.create(line_items: line_items_for(product), canonical_total_cents: 10_00, ip: "24.48.0.1")

          expect(merchant_account.reload.settlement_currency_mismatch_active?(Currency::CAD)).to be(true)
          expect(seller_merchant_account.reload.settlement_currency_mismatch_active?(Currency::CAD)).to be(false)
        end
      end
    end
  end

  # The surcharge endpoint asks this before it publishes a currency menu. It has to answer for the
  # gates that hold in every currency and only those, or the menu either offers currencies the cart
  # can never be quoted in or hides ones it can.
  describe ".cart_quotable?" do
    def quotable?(line_items, canonical_total_cents)
      described_class.cart_quotable?(line_items:, canonical_total_cents:)
    end

    it "accepts a plain paid cart" do
      expect(quotable?(line_items_for(product), 10_00)).to be(true)
    end

    it "refuses a cart with nothing to charge" do
      free = create(:product, user: seller, price_cents: 0)
      expect(quotable?(line_items_for(free), 0)).to be(false)
    end

    it "refuses a cart whose lines do not add up to its total" do
      expect(quotable?(line_items_for(product), 20_00)).to be(false)
    end

    it "refuses a cart spanning more sellers than one request will quote" do
      extra_sellers = Array.new(described_class::MAX_QUOTED_CHARGES) do
        create(:user, disable_buyer_local_currency: false).tap do |extra_seller|
          Feature.activate_user(:buyer_local_currency, extra_seller)
          Feature.activate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, extra_seller)
        end
      end
      products = [product, *extra_sellers.map { create(:product, user: _1, price_cents: 10_00) }]

      expect(quotable?(line_items_for(*products), 10_00 * products.length)).to be(false)
    ensure
      extra_sellers&.each do |extra_seller|
        Feature.deactivate_user(:buyer_local_currency, extra_seller)
        Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, extra_seller)
      end
    end

    it "refuses a paid cart carrying a seller whose own lines are all free" do
      # create() withholds the quote for a seller it would charge nothing, and one withheld charge
      # takes the whole cart back to canonical USD.
      free_seller = create(:user, disable_buyer_local_currency: false).tap do |other|
        Feature.activate_user(:buyer_local_currency, other)
        Feature.activate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, other)
      end
      free_product = create(:product, user: free_seller, price_cents: 0)

      expect(quotable?(line_items_for(product, free_product), 10_00)).to be(false)
    ensure
      Feature.deactivate_user(:buyer_local_currency, free_seller) if free_seller
      Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, free_seller) if free_seller
    end

    it "refuses a cart whose seller is outside the rollout" do
      other = create(:user, disable_buyer_local_currency: false)
      expect(quotable?(line_items_for(create(:product, user: other, price_cents: 10_00)), 10_00)).to be(false)
    end

    it "refuses a cart mixing a membership with a one-off" do
      Feature.activate_user(Checkout::BuyerCurrencyEligibility::SUBSCRIPTION_FEATURE_NAME, seller)
      membership = create(:membership_product, user: seller, price_cents: 10_00)

      expect(quotable?(line_items_for(product, membership), 20_00)).to be(false)
    end

    it "refuses a tip on a cart priced in something other than US dollars" do
      eur_product = create(:product, user: seller, price_cents: 10_00, price_currency_type: Currency::EUR)
      tipped = line_items_for(eur_product)
      tipped.first.tip_cents = 1_00
      tipped.first.price_cents = 9_00

      expect(quotable?(tipped, 10_00)).to be(false)
    end

    # The currency-specific gates stay out of this predicate: they are what lets the endpoint
    # drop one currency from the menu while keeping the rest.
    it "accepts a cart priced in the currency a buyer might ask for" do
      gbp_product = create(:product, user: seller, price_cents: 10_00, price_currency_type: Currency::GBP)

      expect(quotable?(line_items_for(gbp_product), 10_00)).to be(true)
      expect(described_class.create(
               line_items: line_items_for(gbp_product),
               canonical_total_cents: 10_00,
               ip: "24.48.0.1",
               currency: Currency::GBP
             )).to be_nil
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

    it "verifies a EUR-priced cart's token against the purchase totals the charge path computes" do
      # Greptile P1 (2026-07-26) claimed the broadened gate locks LISTED-currency cents in the
      # token while charge-time verification passes USD totals, so a non-USD listing could never
      # complete. This walks both halves with real objects to settle it.
      #
      # Both sides are canonical USD, and neither reads price_currency_type: the checkout sends
      # already-converted prices to the surcharge endpoint (getProducts does
      # `price: convertToUSD(item, price)`), so the line item's price_cents is USD; and the
      # purchase stores `price_cents = displayed_price_usd_cents` with
      # `total_transaction_cents = price_cents`, which is what Order::ChargeService sums into
      # amount_cents. The listing currency only decides how the USD figure was derived.
      eur_product = create(:product, user: seller, price_cents: 10_00, price_currency_type: Currency::EUR)
      eur_purchase = build(:purchase, link: eur_product, seller:, purchase_state: "in_progress")
      # Run the real pricing step rather than trusting the factory, which assigns
      # price_cents straight from the product and so would not exercise the conversion.
      eur_purchase.set_price_and_rate

      # The charge path's own inputs, read off the purchase rather than restated by hand.
      charge_total_cents = eur_purchase.total_transaction_cents
      expect(charge_total_cents).to eq(eur_purchase.price_cents)
      expect(charge_total_cents).not_to eq(eur_product.price_cents), "expected the purchase total to be converted USD, not the listed EUR cents"

      result = described_class.create(
        line_items: [
          described_class::LineItem.new(
            permalink: eur_product.unique_permalink,
            product: eur_product,
            price_cents: charge_total_cents,
            tip_cents: 0,
            seller_tax_cents: 0,
            gumroad_tax_cents: 0,
            shipping_cents: 0
          )
        ],
        canonical_total_cents: charge_total_cents,
        ip: "24.48.0.1"
      )

      verified_quote = described_class.verify!(
        token: result.token,
        seller:,
        merchant_account:,
        currency: Currency::CAD,
        canonical_total_cents: charge_total_cents,
        canonical_line_items: [{ permalink: eur_product.unique_permalink, total_cents: charge_total_cents }]
      )

      expect(verified_quote.currency).to eq(Currency::CAD)
      expect(verified_quote.canonical_total_cents).to eq(charge_total_cents)
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

  describe "listed_currency_rate binding (gumroad-private#1958)" do
    let(:eur_product) { create(:product, user: seller, price_cents: 10_00, price_currency_type: Currency::EUR) }

    def eur_line_item(rate:)
      purchase = build(:purchase, link: eur_product, seller:, purchase_state: "in_progress")
      purchase.set_price_and_rate(locked_rate: rate)
      posted_price_cents = purchase.total_transaction_cents

      tax_result = double(price_cents: posted_price_cents, tax_cents: 0, zip_tax_rate: nil, used_taxjar: false, gumroad_is_mpf: false)
      described_class::LineItem.from_surcharge(
        permalink: eur_product.unique_permalink,
        product: eur_product,
        tax_result:,
        tip_cents: 0,
        shipping_usd_cents: 0,
        listed_currency_rate: rate
      )
    end

    it "binds the listed-currency rate used at quote time into the signed token" do
      line_item = eur_line_item(rate: "0.9")

      result = described_class.create(line_items: [line_item], canonical_total_cents: line_item.canonical_total_cents, ip: "24.48.0.1")

      expect(result.charges.sole.listed_currency_rates).to eq(eur_product.unique_permalink => "0.9")
      expect(result.charges.sole.listed_currency_codes).to eq(eur_product.unique_permalink => Currency::EUR)
    end

    it "omits the rate for USD-listed lines" do
      line_item = line_items_for(product).first

      result = described_class.create(line_items: [line_item], canonical_total_cents: 10_00, ip: "24.48.0.1")

      expect(result.charges.sole.listed_currency_rates).to eq({})
      expect(result.charges.sole.listed_currency_codes).to eq({})
    end

    it "keeps the signed rate scalar for older app instances" do
      line_item = eur_line_item(rate: "0.9")
      created = described_class.create(line_items: [line_item], canonical_total_cents: line_item.canonical_total_cents, ip: "24.48.0.1")
      payload = Rails.application.message_verifier(described_class::TOKEN_PURPOSE).verify(created.token)

      expect(payload.dig("listed_currency_rates", eur_product.unique_permalink).to_d).to eq(BigDecimal("0.9"))
      expect(payload.dig("listed_currency_codes", eur_product.unique_permalink)).to eq(Currency::EUR)
    end

    it "round-trips the rate through verify! so the charge path can read it back" do
      line_item = eur_line_item(rate: "0.9")
      created = described_class.create(line_items: [line_item], canonical_total_cents: line_item.canonical_total_cents, ip: "24.48.0.1")

      verified = described_class.verify!(
        token: created.token,
        seller:,
        merchant_account:,
        currency: Currency::CAD,
        canonical_total_cents: line_item.canonical_total_cents,
        canonical_line_items: [{ permalink: eur_product.unique_permalink, total_cents: line_item.canonical_total_cents }]
      )

      expect(verified.listed_currency_rate_for(eur_product.unique_permalink, currency: Currency::EUR)).to eq(BigDecimal("0.9"))
    end

    it "returns the bound rate from listed_currency_rate_hint while the quote window is open" do
      line_item = eur_line_item(rate: "0.9")
      created = described_class.create(line_items: [line_item], canonical_total_cents: line_item.canonical_total_cents, ip: "24.48.0.1")

      expect(described_class.listed_currency_rate_hint(token: created.token, seller_id: seller.id, permalink: eur_product.unique_permalink, currency: Currency::EUR))
        .to eq(BigDecimal("0.9"))
    end

    it "returns nil from listed_currency_rate_hint when the product currency changed" do
      line_item = eur_line_item(rate: "0.9")
      created = described_class.create(line_items: [line_item], canonical_total_cents: line_item.canonical_total_cents, ip: "24.48.0.1")

      expect(described_class.listed_currency_rate_hint(token: created.token, seller_id: seller.id, permalink: eur_product.unique_permalink, currency: Currency::GBP))
        .to be_nil
    end

    it "returns nil from listed_currency_rate_hint once the quote window has passed" do
      # Load-bearing on non-Stripe charges: PayPal never reaches verify!, so this expiry check
      # is the only thing stopping a replayed old token from pricing a purchase at a stale rate.
      line_item = eur_line_item(rate: "0.9")
      created = described_class.create(line_items: [line_item], canonical_total_cents: line_item.canonical_total_cents, ip: "24.48.0.1")

      travel_to(created.charges.sole.stripe_fx_quote_expires_at + 1.second) do
        expect(described_class.listed_currency_rate_hint(token: created.token, seller_id: seller.id, permalink: eur_product.unique_permalink, currency: Currency::EUR))
          .to be_nil
      end
    end

    it "returns nil from listed_currency_rate_hint for a tampered token" do
      expect(described_class.listed_currency_rate_hint(token: "garbage", seller_id: seller.id, permalink: "whatever", currency: Currency::EUR)).to be_nil
    end

    it "returns nil from listed_currency_rate_hint when no token is present" do
      expect(described_class.listed_currency_rate_hint(token: nil, seller_id: seller.id, permalink: "whatever", currency: Currency::EUR)).to be_nil
    end
  end
end
