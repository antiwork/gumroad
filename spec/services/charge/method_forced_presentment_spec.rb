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
        .with(to_currency: Currency::USD, from_currency: Currency::EUR, stripe_account_id: merchant_account.charge_processor_merchant_id)

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
end
