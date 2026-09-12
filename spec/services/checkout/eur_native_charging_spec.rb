# frozen_string_literal: true

require "spec_helper"

describe "native EUR charging" do
  def platform_account
    MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id)&.tap do |account|
      account.update!(charge_processor_merchant_id: "acct_gumroad", currency: Currency::USD)
    end || create(:merchant_account, user: nil, charge_processor_merchant_id: "acct_gumroad", currency: Currency::USD)
  end

  let(:seller) { create(:user, disable_buyer_local_currency: false, disable_buyer_currency_rounding: true) }
  let(:product) { create(:product, user: seller, price_cents: 10_00, price_currency_type: Currency::USD) }
  let(:merchant_account) { platform_account }
  let(:fx_rate) { BigDecimal("1.1") }

  before do
    merchant_account
    Feature.activate_user(:buyer_local_currency, seller)
    Feature.activate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)
    Feature.activate_user(Checkout::BuyerCurrencyEligibility::EUR_NATIVE_CHARGING_FEATURE_NAME, seller)
    allow(Stripe).to receive(:api_key).and_return("sk_test_eur_native")
  end

  after do
    Feature.deactivate_user(:buyer_local_currency, seller)
    Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)
    Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::EUR_NATIVE_CHARGING_FEATURE_NAME, seller)
  end

  describe Checkout::BuyerCurrencyEligibility do
    let(:purchase) do
      create(:purchase,
             link: product,
             seller:,
             merchant_account:,
             purchase_state: "in_progress",
             ip_address: "203.0.113.1")
    end
    let(:chargeable) { instance_double(Chargeable, get_chargeable_for: instance_double(StripeChargeablePaymentMethod)) }

    def eligibility_decision(currency: Currency::EUR, payment_method: nil)
      token = Rails.application.message_verifier(:buyer_currency_quote).generate({ currency: })
      described_class.new(
        order: create(:order),
        seller:,
        merchant_account:,
        chargeable:,
        purchases: [purchase],
        params: { buyer_currency_quote: token },
        setup_future_charges: false,
        off_session: false
      ).decision(payment_method:)
    end

    it "stays eligible for EUR on the platform account when the mismatch marker is set" do
      merchant_account.record_settlement_currency_mismatch!(Currency::EUR)

      decision = eligibility_decision
      expect(decision).to be_eligible
      expect(decision.currency).to eq(Currency::EUR)
      expect(decision.direct_listed_amount?).to eq(false)
    end

    it "does not keep native EUR eligibility when the buyer pays with iDEAL" do
      merchant_account.record_settlement_currency_mismatch!(Currency::EUR)

      decision = eligibility_decision(payment_method: "ideal")
      expect(decision).not_to be_eligible
      expect(decision.fallback_reason).to eq(:unsupported_settlement_currency)
    end

    it "treats card as native-EUR-eligible and iDEAL/Bancontact/UPI/Pix as not" do
      expect(described_class.eur_native_charging_payment_method?(nil)).to eq(true)
      expect(described_class.eur_native_charging_payment_method?("card")).to eq(true)
      expect(described_class.eur_native_charging_payment_method?("link")).to eq(true)
      %w[ideal bancontact upi pix].each do |method|
        expect(described_class.eur_native_charging_payment_method?(method)).to eq(false)
      end
    end

    it "falls back when the flag is off" do
      Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::EUR_NATIVE_CHARGING_FEATURE_NAME, seller)
      merchant_account.record_settlement_currency_mismatch!(Currency::EUR)

      decision = eligibility_decision
      expect(decision).not_to be_eligible
      expect(decision.fallback_reason).to eq(:unsupported_settlement_currency)
    end

    it "does not apply to Stripe Connect sellers" do
      connect_account = create(:merchant_account_stripe_connect, user: seller)
      seller.update!(check_merchant_account_is_linked: true)
      connect_account.record_settlement_currency_mismatch!(Currency::EUR)
      purchase.update!(merchant_account: connect_account)

      decision = described_class.new(
        order: create(:order),
        seller:,
        merchant_account: connect_account,
        chargeable:,
        purchases: [purchase],
        params: { buyer_currency_quote: Rails.application.message_verifier(:buyer_currency_quote).generate({ currency: Currency::EUR }) },
        setup_future_charges: false,
        off_session: false
      ).decision

      expect(decision).not_to be_eligible
      expect(decision.fallback_reason).to eq(:unsupported_settlement_currency)
    end

    it "excludes memberships, preorders, and shipping" do
      merchant_account.record_settlement_currency_mismatch!(Currency::EUR)

      purchase.update!(link: create(:membership_product, user: seller, price_currency_type: Currency::USD))
      expect(eligibility_decision).not_to be_eligible

      purchase.update!(link: create(:product, user: seller, price_currency_type: Currency::USD, is_in_preorder_state: true), is_preorder_authorization: true)
      expect(eligibility_decision).not_to be_eligible

      purchase.update!(link: create(:physical_product, user: seller, price_currency_type: Currency::USD), shipping_cents: 500, is_preorder_authorization: false)
      expect(eligibility_decision).not_to be_eligible
    end
  end

  describe Checkout::BuyerCurrencyQuote do
    def line_items
      [described_class::LineItem.new(
        permalink: product.unique_permalink,
        product:,
        price_cents: 10_00,
        tip_cents: 0,
        seller_tax_cents: 0,
        gumroad_tax_cents: 0,
        shipping_cents: 0
      )]
    end

    before do
      allow_any_instance_of(described_class).to receive(:buyer_local_currency_rate).and_return(fx_rate)
    end

    it "mints a quote-less EUR lock from the cached rate and does not call Stripe" do
      merchant_account.record_settlement_currency_mismatch!(Currency::EUR)
      expect(StripeFxQuote).not_to receive(:create)

      result = described_class.create(
        line_items:,
        canonical_total_cents: 10_00,
        ip: "203.0.113.1",
        currency: Currency::EUR
      )

      expect(result).to have_attributes(
        currency: Currency::EUR,
        canonical_total_cents: 10_00,
        presentment_total_cents: 909
      )
      payload = Rails.application.message_verifier(:buyer_currency_quote).verify(result.token)
      expect(payload["stripe_fx_quote_id"]).to be_nil
      expect(BigDecimal(payload["fx_rate"])).to eq(fx_rate)
    end

    it "does not mint when the flag is off" do
      Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::EUR_NATIVE_CHARGING_FEATURE_NAME, seller)
      merchant_account.record_settlement_currency_mismatch!(Currency::EUR)
      allow(StripeFxQuote).to receive(:create).and_raise(StripeFxQuote::SettlementCurrencyMismatch, "eur")

      result = described_class.create(
        line_items:,
        canonical_total_cents: 10_00,
        ip: "203.0.113.1",
        currency: Currency::EUR
      )

      expect(result).to be_nil
    end
  end

  describe Charge::CreateService do
    it "creates a EUR PaymentIntent with no Stripe FX quote and keeps seller USD" do
      allow_any_instance_of(Checkout::BuyerCurrencyQuote).to receive(:buyer_local_currency_rate).and_return(fx_rate)
      merchant_account.record_settlement_currency_mismatch!(Currency::EUR)

      quote = Checkout::BuyerCurrencyQuote.create(
        line_items: [Checkout::BuyerCurrencyQuote::LineItem.new(
          permalink: product.unique_permalink,
          product:,
          price_cents: 10_00,
          tip_cents: 0,
          seller_tax_cents: 0,
          gumroad_tax_cents: 0,
          shipping_cents: 0
        )],
        canonical_total_cents: 10_00,
        ip: "203.0.113.1",
        currency: Currency::EUR
      )

      order = create(:order)
      purchase = create(:purchase,
                        link: product,
                        seller:,
                        merchant_account:,
                        purchase_state: "in_progress",
                        ip_address: "203.0.113.1",
                        price_cents: 10_00,
                        total_transaction_cents: 10_00)
      order.purchases << purchase
      stripe_chargeable = instance_double(StripeChargeablePaymentMethod)
      chargeable = instance_double(Chargeable, fingerprint: "card_fp", get_chargeable_for: stripe_chargeable)
      captured = nil

      allow(ChargeProcessor).to receive(:create_payment_intent_or_charge!) do |*args, **kwargs|
        captured = { positional: args, keyword: kwargs }
        expect(ChargePresentment.sole).to have_attributes(
          presentment_currency: Currency::EUR,
          presentment_total_cents: 909,
          stripe_fx_quote_id: nil,
          fx_rate:
        )
        nil
      end

      Charge::CreateService.new(
        order:,
        seller:,
        merchant_account:,
        chargeable:,
        purchases: [purchase],
        amount_cents: 10_00,
        gumroad_amount_cents: 1_50,
        setup_future_charges: false,
        off_session: false,
        statement_description: seller.name_or_username,
        params: { buyer_currency_quote: quote.token }
      ).perform

      expect(captured).to be_present
      expect(captured[:keyword][:processor_currency]).to eq(Currency::EUR)
      expect(captured[:keyword][:processor_amount_cents]).to eq(909)
      expect(captured[:keyword][:stripe_fx_quote_id]).to be_nil
      expect(purchase.reload.total_transaction_cents).to eq(10_00)
    end
  end

  describe Charge::MethodForcedPresentment do
    it "does not persist native EUR presentment when the buyer switches to iDEAL" do
      allow_any_instance_of(Checkout::BuyerCurrencyQuote).to receive(:buyer_local_currency_rate).and_return(fx_rate)
      merchant_account.record_settlement_currency_mismatch!(Currency::EUR)

      quote = Checkout::BuyerCurrencyQuote.create(
        line_items: [Checkout::BuyerCurrencyQuote::LineItem.new(
          permalink: product.unique_permalink,
          product:,
          price_cents: 10_00,
          tip_cents: 0,
          seller_tax_cents: 0,
          gumroad_tax_cents: 0,
          shipping_cents: 0
        )],
        canonical_total_cents: 10_00,
        ip: "203.0.113.1",
        currency: Currency::EUR
      )
      order = create(:order)
      purchase = create(:purchase,
                        link: product,
                        seller:,
                        merchant_account:,
                        purchase_state: "in_progress",
                        ip_address: "203.0.113.1",
                        price_cents: 10_00,
                        total_transaction_cents: 10_00)
      order.purchases << purchase
      charge = create(:charge, order:, seller:, merchant_account:, amount_cents: 10_00, gumroad_amount_cents: 1_50)

      result = described_class.new(
        charge:,
        order:,
        seller:,
        merchant_account:,
        purchases: [purchase],
        amount_cents: 10_00,
        gumroad_amount_cents: 1_50,
        payment_method_type: "ideal",
        params: { buyer_currency_quote: quote.token }
      ).perform

      expect(result).to be_nil
      expect(charge.reload.charge_presentment).to be_nil
    end
  end

  describe "refunds" do
    it "reverses seller USD from the purchase, not a fresh FX rate" do
      purchase = create(:purchase, link: product, seller:, merchant_account:, purchase_state: "successful", price_cents: 10_00, total_transaction_cents: 10_00)
      create(:purchase_presentment,
             purchase:,
             presentment_currency: Currency::EUR,
             presentment_price_cents: 909,
             presentment_gumroad_tax_cents: 0,
             presentment_total_cents: 909,
             presentment_gumroad_amount_cents: 136)
      purchase.association(:purchase_presentment).reset
      allow_any_instance_of(CurrencyHelper).to receive(:buyer_local_currency_rate).and_return(BigDecimal("2"))

      refund = purchase.refunds.build(total_transaction_cents: 10_00)
      amount = purchase.send(:presentment_canonical_refund_issued_amount, refund)

      expect(amount.currency).to eq(Currency::USD)
      expect(amount.cents).to eq(-10_00)
    end
  end
end
