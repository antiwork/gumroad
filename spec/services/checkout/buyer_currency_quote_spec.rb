# frozen_string_literal: true

describe Checkout::BuyerCurrencyQuote do
  let(:seller) { create(:user, check_merchant_account_is_linked: true, disable_buyer_local_currency: false) }
  let(:product) { create(:product, user: seller, price_cents: 10_00, price_currency_type: Currency::USD) }
  let!(:merchant_account) { create(:merchant_account_stripe_connect, user: seller, charge_processor_merchant_id: "acct_connect", currency: Currency::USD) }
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
      result = described_class.create(products: [product], canonical_total_cents: 10_00, ip: "24.48.0.1")

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

      result = described_class.create(products: [product], canonical_total_cents: 10_00, ip: "24.48.0.1")

      expect(result).to be_nil
    end

    it "returns nil for multi-product checkouts" do
      expect(StripeFxQuote).not_to receive(:create)

      result = described_class.create(products: [product, create(:product, user: seller)], canonical_total_cents: 20_00, ip: "24.48.0.1")

      expect(result).to be_nil
    end

    it "returns nil when the seller only has the Gumroad platform account" do
      merchant_account.destroy!
      MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id)&.tap do |account|
        account.update!(charge_processor_merchant_id: "acct_gumroad", currency: Currency::USD)
      end || create(:merchant_account, user: nil, charge_processor_merchant_id: "acct_gumroad", currency: Currency::USD)
      expect(StripeFxQuote).not_to receive(:create)

      result = described_class.create(products: [product], canonical_total_cents: 10_00, ip: "24.48.0.1")

      expect(result).to be_nil
    end
  end

  describe ".verify!" do
    it "returns the locked quote when the checkout context matches" do
      result = described_class.create(products: [product], canonical_total_cents: 10_00, ip: "24.48.0.1")

      verified_quote = described_class.verify!(
        token: result.token,
        seller:,
        merchant_account:,
        currency: Currency::CAD,
        canonical_total_cents: 10_00
      )

      expect(verified_quote).to have_attributes(currency: Currency::CAD,
                                                canonical_total_cents: 10_00,
                                                presentment_total_cents: 12_50,
                                                fx_rate: BigDecimal("0.8"),
                                                stripe_fx_quote_id: "fxq_test")
    end

    it "rejects tokens when the canonical total changes" do
      result = described_class.create(products: [product], canonical_total_cents: 10_00, ip: "24.48.0.1")

      expect do
        described_class.verify!(
          token: result.token,
          seller:,
          merchant_account:,
          currency: Currency::CAD,
          canonical_total_cents: 11_00
        )
      end.to raise_error(described_class::InvalidToken, "total mismatch")
    end

    it "rejects expired tokens" do
      result = described_class.create(products: [product], canonical_total_cents: 10_00, ip: "24.48.0.1")

      travel_to stripe_fx_quote.expires_at + 1.second do
        expect do
          described_class.verify!(
            token: result.token,
            seller:,
            merchant_account:,
            currency: Currency::CAD,
            canonical_total_cents: 10_00
          )
        end.to raise_error(described_class::InvalidToken, "expired buyer currency quote")
      end
    end
  end
end
