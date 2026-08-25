# frozen_string_literal: true

require "spec_helper"

describe Charge::MethodForcedPresentment do
  let(:seller) { create(:user, disable_buyer_local_currency: false) }
  let(:merchant_account) { create(:merchant_account_stripe_connect, user: seller) }
  let(:order) { create(:order) }
  let(:charge) { create(:charge, order:, seller:, merchant_account:, amount_cents: 10_00, gumroad_amount_cents: 3_00) }
  let(:product) { create(:product, user: seller, price_currency_type: Currency::USD, price_cents: 10_00) }
  let(:purchase) do
    create(:purchase,
           link: product,
           seller:,
           merchant_account:,
           price_cents: 10_00,
           total_transaction_cents: 10_00)
  end
  let(:payment_method_type) { "ideal" }

  subject(:result) do
    described_class.new(charge:,
                        order:,
                        seller:,
                        merchant_account:,
                        purchases: [purchase],
                        amount_cents: 10_00,
                        gumroad_amount_cents: 3_00,
                        payment_method_type:,
                        params: {}).perform
  end

  before do
    Feature.activate_user(:buyer_local_currency, seller)
    Feature.activate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)
    allow(Stripe).to receive(:api_key).and_return("sk_test_currency")
  end

  after do
    Feature.deactivate_user(:buyer_local_currency, seller)
    Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)
  end

  describe "USD-priced product (FX quote case)" do
    let(:quote) do
      StripeFxQuote::Quote.new(id: "fxq_forced", expires_at: 30.minutes.from_now, fx_rate: BigDecimal("1.25"))
    end

    before { allow(StripeFxQuote).to receive(:create).and_return(quote) }

    it "mints an FX quote, persists quote-backed presentment rows, and converts through the quote" do
      # 10_00 USD cents / 1.25 USD-per-EUR = 8_00 EUR cents; 3_00 / 1.25 = 2_40.
      expect(result).to have_attributes(presentment_total_cents: 8_00,
                                        presentment_currency: Currency::EUR,
                                        presentment_gumroad_amount_cents: 2_40,
                                        stripe_fx_quote_id: "fxq_forced")

      expect(StripeFxQuote).to have_received(:create)
        .with(to_currency: Currency::USD,
              from_currency: Currency::EUR,
              stripe_account_id: merchant_account.charge_processor_merchant_id,
              destination_account_id: nil)

      charge_presentment = charge.reload.charge_presentment
      expect(charge_presentment).to have_attributes(processor: StripeChargeProcessor.charge_processor_id,
                                                    presentment_currency: Currency::EUR,
                                                    presentment_total_cents: 8_00,
                                                    presentment_gumroad_amount_cents: 2_40,
                                                    stripe_fx_quote_id: "fxq_forced",
                                                    fx_rate: BigDecimal("1.25"))
      expect(charge_presentment.stripe_fx_quote_expires_at).to be_present

      expect(purchase.reload.purchase_presentment).to have_attributes(charge_presentment:,
                                                                      presentment_currency: Currency::EUR,
                                                                      presentment_price_cents: 8_00,
                                                                      presentment_total_cents: 8_00,
                                                                      presentment_gumroad_amount_cents: 2_40)
    end

    it "returns a quote-derived idempotency key" do
      expect(result.idempotency_key).to eq("buyer-currency-intent-#{charge.external_id}-fxq_forced")
    end

    context "when checkout already displayed a locked quote" do
      def displayed_quote_token(stripe_fx_quote_id:, fx_rate:, presentment_total_cents:)
        charge_payload = {
          "seller_id" => seller.id,
          "merchant_account_id" => merchant_account.id,
          "stripe_account_id" => merchant_account.charge_processor_merchant_id,
          "canonical_total_cents" => 10_00,
          "canonical_line_items" => [[product.unique_permalink, 10_00]],
          "presentment_total_cents" => presentment_total_cents,
          "charge_canonical_total_cents" => 10_00,
          "charge_canonical_line_items" => [[product.unique_permalink, 10_00]],
          "charge_presentment_total_cents" => presentment_total_cents,
          "stripe_fx_quote_id" => stripe_fx_quote_id,
          "stripe_fx_quote_expires_at" => 30.minutes.from_now.iso8601,
          "fx_rate" => fx_rate.to_s("F"),
        }
        Rails.application.message_verifier(Checkout::BuyerCurrencyQuote::TOKEN_PURPOSE).generate(
          charge_payload.merge("currency" => Currency::EUR, "charges" => [charge_payload])
        )
      end

      it "reuses the displayed quote instead of minting a second rate" do
        token = displayed_quote_token(stripe_fx_quote_id: "fxq_displayed", fx_rate: BigDecimal("1.25"), presentment_total_cents: 8_00)
        expect(StripeFxQuote).not_to receive(:create)

        reused = described_class.new(charge:,
                                     order:,
                                     seller:,
                                     merchant_account:,
                                     purchases: [purchase],
                                     amount_cents: 10_00,
                                     gumroad_amount_cents: 3_00,
                                     payment_method_type:,
                                     params: { buyer_currency_quote: token }).perform

        expect(reused).to have_attributes(presentment_total_cents: 8_00,
                                          presentment_currency: Currency::EUR,
                                          stripe_fx_quote_id: "fxq_displayed")
        expect(charge.reload.charge_presentment.stripe_fx_quote_id).to eq("fxq_displayed")
      end

      it "fails closed when the displayed quote does not match this charge" do
        token = displayed_quote_token(stripe_fx_quote_id: "fxq_stale", fx_rate: BigDecimal("1.25"), presentment_total_cents: 8_00)
        expect(StripeFxQuote).not_to receive(:create)

        mismatched = described_class.new(charge:,
                                         order:,
                                         seller:,
                                         merchant_account:,
                                         purchases: [purchase],
                                         amount_cents: 11_00,
                                         gumroad_amount_cents: 3_00,
                                         payment_method_type:,
                                         params: { buyer_currency_quote: token }).perform

        expect(mismatched).to be_nil
        expect(charge.reload.charge_presentment).to be_nil
      end
    end
  end

  describe "product priced in the forced currency (direct listed-amount case)" do
    # 15_00 EUR listed price; rate_converted_to_usd expresses EUR per USD (usd_cents_to_currency
    # multiplies by it), so 0.8 means the canonical USD figures are displayed/0.8.
    let(:product) { create(:product, user: seller, price_currency_type: Currency::EUR, price_cents: 15_00) }
    let(:purchase) do
      create(:purchase,
             link: product,
             seller:,
             merchant_account:,
             displayed_price_cents: 15_00,
             displayed_price_currency_type: Currency::EUR,
             rate_converted_to_usd: "0.8",
             price_cents: 18_75,
             total_transaction_cents: 18_75)
    end

    subject(:result) do
      described_class.new(charge:,
                          order:,
                          seller:,
                          merchant_account:,
                          purchases: [purchase],
                          amount_cents: 18_75,
                          gumroad_amount_cents: 3_00,
                          payment_method_type:,
                          params: {}).perform
    end

    it "charges the listed amount directly without fetching an FX quote and leaves quote columns null" do
      expect(StripeFxQuote).not_to receive(:create)

      expect(result).to have_attributes(presentment_total_cents: 15_00,
                                        presentment_currency: Currency::EUR,
                                        stripe_fx_quote_id: nil)
      # Gumroad's share converts back with the purchase's own stored rate: 3_00 * 0.8 = 2_40.
      expect(result.presentment_gumroad_amount_cents).to eq(2_40)

      charge_presentment = charge.reload.charge_presentment
      expect(charge_presentment).to have_attributes(presentment_currency: Currency::EUR,
                                                    presentment_total_cents: 15_00,
                                                    presentment_gumroad_amount_cents: 2_40,
                                                    stripe_fx_quote_id: nil,
                                                    stripe_fx_quote_expires_at: nil,
                                                    fx_rate: nil)

      expect(purchase.reload.purchase_presentment).to have_attributes(charge_presentment:,
                                                                      presentment_currency: Currency::EUR,
                                                                      presentment_price_cents: 15_00,
                                                                      presentment_tip_cents: 0,
                                                                      presentment_total_cents: 15_00)
    end

    it "sums the listed amount with tip, tax, and shipping in the forced currency" do
      purchase.build_tip(value_cents: 2_00, value_usd_cents: 2_50).save!
      # displayed_price_cents already contains the tip (it is part of what the buyer picked);
      # USD-stored components convert back with the stored rate: tax 1_00 USD -> 80 EUR cents,
      # shipping 2_00 USD -> 1_60 EUR cents.
      purchase.update!(displayed_price_cents: 17_00,
                       gumroad_tax_cents: 1_00,
                       shipping_cents: 2_00,
                       total_transaction_cents: 23_50)

      expect(result.presentment_total_cents).to eq(17_00 + 80 + 1_60)
      expect(purchase.reload.purchase_presentment).to have_attributes(presentment_tip_cents: 2_00,
                                                                      presentment_gumroad_tax_cents: 80,
                                                                      presentment_shipping_cents: 1_60,
                                                                      presentment_price_cents: 15_00,
                                                                      presentment_total_cents: 19_40)
    end

    it "adds excluded seller tax to the forced-currency total" do
      purchase.update!(tax_cents: 1_00,
                       was_tax_excluded_from_price: true,
                       total_transaction_cents: 19_75)

      expect(result.presentment_total_cents).to eq(15_00 + 80)
      expect(purchase.reload.purchase_presentment).to have_attributes(presentment_seller_tax_cents: 80,
                                                                      presentment_price_cents: 15_00,
                                                                      presentment_total_cents: 15_80)
    end

    it "keeps included seller tax inside the forced-currency total and splits it out from price" do
      purchase.update!(tax_cents: 1_00,
                       was_tax_excluded_from_price: false,
                       total_transaction_cents: 18_75)

      expect(result.presentment_total_cents).to eq(15_00)
      expect(purchase.reload.purchase_presentment).to have_attributes(presentment_seller_tax_cents: 80,
                                                                      presentment_price_cents: 14_20,
                                                                      presentment_total_cents: 15_00)
    end

    it "returns a stable idempotency key derived from the charge and currency, without any quote" do
      expect(result.idempotency_key).to eq("buyer-currency-intent-#{charge.external_id}-#{Currency::EUR}")
    end

    it "persists direct listed-amount allocations for a multi-item forced-currency cart" do
      other_product = create(:product, user: seller, price_currency_type: Currency::EUR, price_cents: 7_00)
      other_purchase = create(:purchase,
                              link: other_product,
                              seller:,
                              merchant_account:,
                              displayed_price_cents: 7_00,
                              displayed_price_currency_type: Currency::EUR,
                              rate_converted_to_usd: "0.8",
                              price_cents: 8_75,
                              total_transaction_cents: 8_75)
      charge.update!(amount_cents: 27_50, gumroad_amount_cents: purchase.total_transaction_amount_for_gumroad_cents + other_purchase.total_transaction_amount_for_gumroad_cents)

      expect(StripeFxQuote).not_to receive(:create)

      multi_result = described_class.new(charge:,
                                         order:,
                                         seller:,
                                         merchant_account:,
                                         purchases: [purchase, other_purchase],
                                         amount_cents: 27_50,
                                         gumroad_amount_cents: charge.gumroad_amount_cents,
                                         payment_method_type:,
                                         params: {}).perform

      expect(multi_result).to have_attributes(presentment_total_cents: 22_00,
                                              presentment_currency: Currency::EUR,
                                              stripe_fx_quote_id: nil)
      expect(charge.reload.charge_presentment).to have_attributes(presentment_currency: Currency::EUR,
                                                                  presentment_total_cents: 22_00,
                                                                  stripe_fx_quote_id: nil)
      expect(purchase.reload.purchase_presentment).to have_attributes(presentment_total_cents: 15_00)
      expect(other_purchase.reload.purchase_presentment).to have_attributes(presentment_total_cents: 7_00)
    end

    it "falls back to the canonical USD path when the purchase has no stored conversion rate" do
      purchase.update!(rate_converted_to_usd: nil)

      expect(ErrorNotifier).to receive(:notify)
        .with(an_instance_of(RuntimeError).and(having_attributes(message: a_string_including("rate_converted_to_usd must be set"))),
              context: hash_including(charge_id: charge.id))
      expect(result).to be_nil
      expect(charge.reload.charge_presentment).to be_nil
    end

    it "falls back to the canonical USD path when the tip exceeds the displayed price (broken tip-inclusion invariant)" do
      purchase.build_tip(value_cents: 20_00, value_usd_cents: 25_00).save!

      expect(ErrorNotifier).to receive(:notify)
        .with(an_instance_of(RuntimeError).and(having_attributes(message: a_string_including("displayed_price_cents must include tip"))),
              context: hash_including(charge_id: charge.id))
      expect(result).to be_nil
      expect(charge.reload.charge_presentment).to be_nil
    end

    it "caps the converted Gumroad share at the purchase's presentment total" do
      # The Gumroad share is converted from canonical cents independently of the
      # listed-price-based total, so adverse rounding on a ~100% Gumroad cut could put
      # it a cent above the purchase total — which would fail PurchasePresentment's
      # gumroad-amount validation and degrade this lane to an unconfirmable USD intent.
      # 18_76 canonical Gumroad cents * 0.8 = 15_01 EUR > the 15_00 EUR listed total.
      charge.update!(gumroad_amount_cents: 18_76)

      capped = described_class.new(charge:,
                                   order:,
                                   seller:,
                                   merchant_account:,
                                   purchases: [purchase],
                                   amount_cents: 18_75,
                                   gumroad_amount_cents: 18_76,
                                   payment_method_type:,
                                   params: {}).perform

      expect(capped.presentment_gumroad_amount_cents).to eq(15_00)
      expect(purchase.reload.purchase_presentment.presentment_gumroad_amount_cents).to eq(15_00)
    end
  end

  describe ".idempotency_key_for" do
    it "returns the same key for the same inputs (quote-less flow)" do
      key_one = described_class.idempotency_key_for(charge:, presentment_currency: Currency::EUR)
      key_two = described_class.idempotency_key_for(charge:, presentment_currency: Currency::EUR)

      expect(key_one).to eq(key_two)
      expect(key_one).to be_present
    end

    it "keys quote-backed flows on the FX quote id" do
      key = described_class.idempotency_key_for(charge:, presentment_currency: Currency::EUR, stripe_fx_quote_id: "fxq_abc")

      expect(key).to eq("buyer-currency-intent-#{charge.external_id}-fxq_abc")
      expect(key).not_to eq(described_class.idempotency_key_for(charge:, presentment_currency: Currency::EUR))
    end

    it "differs across charges and currencies" do
      other_charge = create(:charge, order:, seller:, merchant_account:)

      expect(described_class.idempotency_key_for(charge:, presentment_currency: Currency::EUR))
        .not_to eq(described_class.idempotency_key_for(charge: other_charge, presentment_currency: Currency::EUR))
    end
  end

  describe "ineligible checkouts" do
    it "returns nil and persists nothing when the feature flag is off" do
      Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)

      expect(result).to be_nil
      expect(charge.reload.charge_presentment).to be_nil
      expect(purchase.reload.purchase_presentment).to be_nil
    end

    it "returns nil for a payment method without a forced currency" do
      expect(described_class.new(charge:,
                                 order:,
                                 seller:,
                                 merchant_account:,
                                 purchases: [purchase],
                                 amount_cents: 10_00,
                                 gumroad_amount_cents: 3_00,
                                 payment_method_type: "card",
                                 params: {}).perform).to be_nil
      expect(charge.reload.charge_presentment).to be_nil
    end

    it "falls back to nil without partial rows when persistence fails" do
      allow(ErrorNotifier).to receive(:notify)
      allow(StripeFxQuote).to receive(:create).and_return(
        StripeFxQuote::Quote.new(id: "fxq_boom", expires_at: 30.minutes.from_now, fx_rate: BigDecimal("1.25"))
      )
      allow(Charge::PresentmentOrchestrator).to receive(:persist!).and_raise("persistence failed")

      expect(result).to be_nil
      expect(charge.reload.charge_presentment).to be_nil
      expect(ErrorNotifier).to have_received(:notify).with(instance_of(RuntimeError), context: hash_including(charge_id: charge.id))
    end

    it "falls back to nil without notifying Sentry when the account settles in a non-USD currency" do
      # Expected condition (Stripe multi-currency settlement), not a defect — the intent
      # is prepared in USD as before, and no error notification is sent.
      allow(StripeFxQuote).to receive(:create).and_raise(
        StripeFxQuote::SettlementCurrencyMismatch, "FX quote settles in cad, expected usd"
      )
      expect(ErrorNotifier).not_to receive(:notify)

      expect(result).to be_nil
      expect(charge.reload.charge_presentment).to be_nil
    end

    it "records the settlement-currency mismatch on the merchant account for later checkouts" do
      allow(StripeFxQuote).to receive(:create).and_raise(
        StripeFxQuote::SettlementCurrencyMismatch, "FX quote settles in cad, expected usd"
      )

      expect { result }.to change { merchant_account.reload.settlement_currency_mismatch_active?("eur") }.from(false).to(true)
    end
  end

  describe "destination charge" do
    # A Gumroad-managed Stripe Custom account: it belongs to a user, so it is not the
    # platform row, but it is not a Stripe Connect account either — Stripe charges it with
    # a destination charge, creating the PaymentIntent on the Gumroad platform account.
    let(:merchant_account) { create(:merchant_account, user: seller, currency: Currency::USD) }
    let!(:platform_merchant_account) do
      MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id)&.tap do |account|
        account.update!(charge_processor_merchant_id: "acct_gumroad_platform", currency: Currency::USD)
      end || create(:merchant_account, user: nil, charge_processor_merchant_id: "acct_gumroad_platform", currency: Currency::USD)
    end

    # Destination charges have never minted an FX quote in production, so quoting one is new
    # behaviour against real money and is gated on the same ramp flag as the card lane. With
    # the flag off this lane withholds the quote without calling Stripe at all.
    #
    # Returning nil is NOT the card lane's quiet canonical-USD fallback: this is the quoted
    # case, whose caller (Order::PreparePaymentIntentService#client_confirm_presentment_required?)
    # turns a nil presentment into a clean synchronous failure, because the buyer's token was
    # minted on a forced-currency element and could never confirm a USD intent. That end of the
    # contract is pinned in the prepare-service spec; here we only pin that no quote is minted.
    it "withholds the quote without calling Stripe while the ramp flag is off" do
      allow(StripeFxQuote).to receive(:create)

      expect(result).to be_nil
      expect(StripeFxQuote).not_to have_received(:create)
    end

    context "when the destination-charge ramp flag is on" do
      before { Feature.activate_user(Checkout::BuyerCurrencyEligibility::DESTINATION_CHARGE_FEATURE_NAME, seller) }

      it "mints the quote on the platform account, which is where the intent is created" do
        allow(StripeFxQuote).to receive(:create).and_return(
          StripeFxQuote::Quote.new(id: "fxq_destination", expires_at: 30.minutes.from_now, fx_rate: BigDecimal("1.25"))
        )

        expect(result.stripe_fx_quote_id).to eq("fxq_destination")
        expect(StripeFxQuote).to have_received(:create)
          .with(to_currency: Currency::USD,
                from_currency: Currency::EUR,
                stripe_account_id: "acct_gumroad_platform",
                # The intent for a destination charge carries transfer_data[destination], and
                # Stripe refuses a quote that does not name the same account.
                destination_account_id: merchant_account.charge_processor_merchant_id)
      end

      it "records a settlement-currency mismatch on the platform account rather than the seller's" do
        allow(StripeFxQuote).to receive(:create).and_raise(
          StripeFxQuote::SettlementCurrencyMismatch, "FX quote settles in eur, expected usd"
        )

        expect { result }.to change { platform_merchant_account.reload.settlement_currency_mismatch_active?("eur") }.from(false).to(true)
        expect(merchant_account.reload.settlement_currency_mismatch_active?("eur")).to be(false)
      end
    end
  end
end
