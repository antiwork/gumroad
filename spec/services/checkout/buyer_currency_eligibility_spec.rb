# frozen_string_literal: true

require "spec_helper"

describe Checkout::BuyerCurrencyEligibility do
  let(:seller) { create(:user, disable_buyer_local_currency: false) }
  let(:product) { create(:product, user: seller, price_currency_type: Currency::USD) }
  let(:merchant_account) { create(:merchant_account_stripe_connect, user: seller) }
  let(:purchase) do
    create(:purchase,
           link: product,
           seller:,
           merchant_account:,
           purchase_state: "in_progress",
           ip_address: "203.0.113.1")
  end
  let(:purchases) { [purchase] }
  let(:order) { create(:order) }
  let(:stripe_chargeable) { instance_double(StripeChargeablePaymentMethod) }
  let(:chargeable) { instance_double(Chargeable, get_chargeable_for: stripe_chargeable) }
  let(:params) { {} }
  let(:setup_future_charges) { false }
  let(:off_session) { false }

  subject(:decision) do
    described_class.new(order:,
                        seller:,
                        merchant_account:,
                        chargeable:,
                        purchases:,
                        params:,
                        setup_future_charges:,
                        off_session:).decision
  end

  before do
    Feature.activate_user(:buyer_local_currency, seller)
    Feature.activate_user(described_class::FEATURE_NAME, seller)
    allow_any_instance_of(described_class).to receive(:buyer_currency_for_ip).and_return(Currency::CAD)
    allow(Stripe).to receive(:api_key).and_return("sk_test_currency")
  end

  after do
    Feature.deactivate_user(:buyer_local_currency, seller)
    Feature.deactivate_user(described_class::FEATURE_NAME, seller)
  end

  it "allows the PR1 Stripe test-mode direct-charge path" do
    expect(decision).to be_eligible
    expect(decision.currency).to eq(Currency::CAD)
    expect(decision.fallback_reason).to be_nil
  end

  it "allows the PR1 Stripe test-mode Gumroad platform-account path" do
    platform_merchant_account = create(:merchant_account, user: nil, charge_processor_id: StripeChargeProcessor.charge_processor_id, currency: Currency::USD)
    purchase.update!(merchant_account: platform_merchant_account)

    platform_decision = described_class.new(order:,
                                            seller:,
                                            merchant_account: platform_merchant_account,
                                            chargeable:,
                                            purchases:,
                                            params:,
                                            setup_future_charges:,
                                            off_session:).decision

    expect(platform_decision).to be_eligible
    expect(platform_decision.currency).to eq(Currency::CAD)
    expect(platform_decision.fallback_reason).to be_nil
  end

  it "falls back when the internal rollout flag is disabled" do
    Feature.deactivate_user(described_class::FEATURE_NAME, seller)

    expect(decision).not_to be_eligible
    expect(decision.fallback_reason).to eq(:feature_disabled)
  end

  it "stays eligible in live mode now that the card presentment path has shipped its safety gates" do
    allow(Stripe).to receive(:api_key).and_return("sk_live_currency")

    expect(decision).to be_eligible
    expect(decision.currency).to eq(Currency::CAD)
    expect(decision.fallback_reason).to be_nil
  end

  it "falls back for commission deposit purchases even when a quote token is present" do
    seller.update!(created_at: User::MIN_AGE_FOR_SERVICE_PRODUCTS.ago - 1.day)
    purchase.update!(link: create(:commission_product, user: seller), is_commission_deposit_purchase: true)

    expect(decision).not_to be_eligible
    expect(decision.fallback_reason).to eq(:unsupported_product_type)
  end

  it "falls back for installment payments" do
    purchase.update!(is_installment_payment: true)

    expect(decision).not_to be_eligible
    expect(decision.fallback_reason).to eq(:unsupported_product_type)
  end

  it "falls back for buyer currencies Gumroad stores in different minor units than Stripe charges" do
    allow_any_instance_of(described_class).to receive(:buyer_currency_for_ip).and_return(Currency::KRW)

    expect(decision).not_to be_eligible
    expect(decision.fallback_reason).to eq(:unsupported_buyer_currency)
  end

  it "falls back for buyer currencies Stripe only charges in amounts divisible by 100" do
    allow_any_instance_of(described_class).to receive(:buyer_currency_for_ip).and_return(Currency::TWD)

    expect(decision).not_to be_eligible
    expect(decision.fallback_reason).to eq(:unsupported_buyer_currency)
  end

  it "allows zero-decimal buyer currencies that Gumroad also stores in whole units" do
    allow_any_instance_of(described_class).to receive(:buyer_currency_for_ip).and_return(Currency::JPY)

    expect(decision).to be_eligible
    expect(decision.currency).to eq(Currency::JPY)
  end

  it "falls back for wallet payment requests" do
    params[:wallet_type] = "apple_pay"

    expect(decision).not_to be_eligible
    expect(decision.fallback_reason).to eq(:wallet_payment_request)
  end

  it "falls back for future-charge card setups such as save-card checkouts" do
    save_card_decision = described_class.new(order:,
                                             seller:,
                                             merchant_account:,
                                             chargeable:,
                                             purchases:,
                                             params:,
                                             setup_future_charges: true,
                                             off_session:).decision

    expect(save_card_decision).not_to be_eligible
    expect(save_card_decision.fallback_reason).to eq(:future_charge_setup)
  end

  it "falls back for multi-item checkouts" do
    purchases << create(:purchase, link: product, seller:, merchant_account:, purchase_state: "in_progress")

    expect(decision).not_to be_eligible
    expect(decision.fallback_reason).to eq(:multi_item_checkout)
  end

  it "falls back for seller-managed destination-charge models" do
    merchant_account.update!(json_data: {})

    expect(decision).not_to be_eligible
    expect(decision.fallback_reason).to eq(:unsupported_charge_model)
  end

  describe "#method_forced_decision" do
    let(:payment_method) { "ideal" }

    subject(:forced_decision) do
      described_class.new(order:,
                          seller:,
                          merchant_account:,
                          chargeable:,
                          purchases:,
                          params:,
                          setup_future_charges:,
                          off_session:).method_forced_decision(payment_method:)
    end

    it "allows iDEAL in EUR for a USD-priced product via the FX quote path" do
      expect(forced_decision).to be_eligible
      expect(forced_decision.currency).to eq(Currency::EUR)
      expect(forced_decision.fallback_reason).to be_nil
      expect(forced_decision.direct_listed_amount?).to eq(false)
    end

    it "allows iDEAL in EUR for an EUR-priced product and flags the direct listed-amount case" do
      purchase.update!(link: create(:product, user: seller, price_currency_type: Currency::EUR))

      expect(forced_decision).to be_eligible
      expect(forced_decision.currency).to eq(Currency::EUR)
      expect(forced_decision.direct_listed_amount?).to eq(true)
    end

    it "allows Bancontact in EUR" do
      bancontact_decision = described_class.new(order:,
                                                seller:,
                                                merchant_account:,
                                                chargeable:,
                                                purchases:,
                                                params:,
                                                setup_future_charges:,
                                                off_session:).method_forced_decision(payment_method: "bancontact")

      expect(bancontact_decision).to be_eligible
      expect(bancontact_decision.currency).to eq(Currency::EUR)
    end

    it "does not depend on GeoIP buyer currency detection" do
      allow_any_instance_of(described_class).to receive(:buyer_currency_for_ip).and_raise("GeoIP must not be consulted in method-forced mode")

      expect(forced_decision).to be_eligible
      expect(forced_decision.currency).to eq(Currency::EUR)
    end

    it "withholds the method for payment methods without a forced currency" do
      unknown_decision = described_class.new(order:,
                                             seller:,
                                             merchant_account:,
                                             chargeable:,
                                             purchases:,
                                             params:,
                                             setup_future_charges:,
                                             off_session:).method_forced_decision(payment_method: "card")

      expect(unknown_decision).not_to be_eligible
      expect(unknown_decision.fallback_reason).to eq(:unsupported_payment_method)
    end

    # Scenario-4 shape (round-2 QA): a card ConfirmationToken minted on an EUR-mounted
    # Payment Element can only confirm an EUR intent, so the prepare service passes the
    # element's mount currency explicitly for methods with no registry entry of their own.
    it "allows card with an explicit forced currency (EUR-mounted element) and flags the direct listed-amount case" do
      purchase.update!(link: create(:product, user: seller, price_currency_type: Currency::EUR))

      card_decision = described_class.new(order:,
                                          seller:,
                                          merchant_account:,
                                          chargeable:,
                                          purchases:,
                                          params:,
                                          setup_future_charges:,
                                          off_session:).method_forced_decision(payment_method: "card", forced_currency: Currency::EUR)

      expect(card_decision).to be_eligible
      expect(card_decision.currency).to eq(Currency::EUR)
      expect(card_decision.direct_listed_amount?).to eq(true)
    end

    it "still applies the flag gates when the forced currency is explicit" do
      Feature.deactivate_user(described_class::FEATURE_NAME, seller)

      card_decision = described_class.new(order:,
                                          seller:,
                                          merchant_account:,
                                          chargeable:,
                                          purchases:,
                                          params:,
                                          setup_future_charges:,
                                          off_session:).method_forced_decision(payment_method: "card", forced_currency: Currency::EUR)

      expect(card_decision).not_to be_eligible
      expect(card_decision.fallback_reason).to eq(:feature_disabled)
    end

    it "withholds the method when the internal rollout flag is disabled" do
      Feature.deactivate_user(described_class::FEATURE_NAME, seller)

      expect(forced_decision).not_to be_eligible
      expect(forced_decision.fallback_reason).to eq(:feature_disabled)
    end

    it "withholds the method in live mode when its launch flag is off" do
      allow(Stripe).to receive(:api_key).and_return("sk_live_currency")

      expect(forced_decision).not_to be_eligible
      expect(forced_decision.fallback_reason).to eq(:method_not_launched)
    end

    it "allows the method in live mode when its per-method launch flag is on" do
      allow(Stripe).to receive(:api_key).and_return("sk_live_currency")
      Feature.activate_user(:checkout_local_method_ideal, seller)

      expect(forced_decision).to be_eligible
      expect(forced_decision.currency).to eq(Currency::EUR)
    end

    it "does not let one method's launch flag launch a sibling method in live mode" do
      allow(Stripe).to receive(:api_key).and_return("sk_live_currency")
      Feature.activate_user(:checkout_local_method_ideal, seller)

      bancontact_decision = described_class.new(order:,
                                                seller:,
                                                merchant_account:,
                                                chargeable:,
                                                purchases:,
                                                params:,
                                                setup_future_charges:,
                                                off_session:).method_forced_decision(payment_method: "bancontact")

      expect(bancontact_decision).not_to be_eligible
      expect(bancontact_decision.fallback_reason).to eq(:method_not_launched)
    end

    it "allows a card token from a forced-currency element in live mode when a method forcing that currency is launched" do
      allow(Stripe).to receive(:api_key).and_return("sk_live_currency")
      Feature.activate_user(:checkout_local_method_ideal, seller)
      purchase.update!(link: create(:product, user: seller, price_currency_type: Currency::EUR))

      card_decision = described_class.new(order:,
                                          seller:,
                                          merchant_account:,
                                          chargeable:,
                                          purchases:,
                                          params:,
                                          setup_future_charges:,
                                          off_session:).method_forced_decision(payment_method: "card", forced_currency: Currency::EUR)

      expect(card_decision).to be_eligible
      expect(card_decision.currency).to eq(Currency::EUR)
    end

    it "withholds a card token from a forced-currency element in live mode when no method forcing that currency is launched" do
      allow(Stripe).to receive(:api_key).and_return("sk_live_currency")
      purchase.update!(link: create(:product, user: seller, price_currency_type: Currency::EUR))

      card_decision = described_class.new(order:,
                                          seller:,
                                          merchant_account:,
                                          chargeable:,
                                          purchases:,
                                          params:,
                                          setup_future_charges:,
                                          off_session:).method_forced_decision(payment_method: "card", forced_currency: Currency::EUR)

      expect(card_decision).not_to be_eligible
      expect(card_decision.fallback_reason).to eq(:method_not_launched)
    end

    it "withholds the method for non-Stripe merchant accounts" do
      paypal_merchant_account = create(:merchant_account_paypal, user: seller)
      paypal_decision = described_class.new(order:,
                                            seller:,
                                            merchant_account: paypal_merchant_account,
                                            chargeable:,
                                            purchases:,
                                            params:,
                                            setup_future_charges:,
                                            off_session:).method_forced_decision(payment_method:)

      expect(paypal_decision).not_to be_eligible
      expect(paypal_decision.fallback_reason).to eq(:unsupported_processor)
    end

    it "withholds the method for seller-managed destination-charge models" do
      merchant_account.update!(json_data: {})

      expect(forced_decision).not_to be_eligible
      expect(forced_decision.fallback_reason).to eq(:unsupported_charge_model)
    end

    it "withholds the method for merchant accounts that settle in a non-USD currency, even for EUR-priced products" do
      purchase.update!(link: create(:product, user: seller, price_currency_type: Currency::EUR))
      merchant_account.update!(currency: Currency::CAD)

      expect(forced_decision).not_to be_eligible
      expect(forced_decision.fallback_reason).to eq(:unsupported_settlement_currency)
    end

    it "withholds the method for future-charge setups such as save-card checkouts" do
      save_card_decision = described_class.new(order:,
                                               seller:,
                                               merchant_account:,
                                               chargeable:,
                                               purchases:,
                                               params:,
                                               setup_future_charges: true,
                                               off_session:).method_forced_decision(payment_method:)

      expect(save_card_decision).not_to be_eligible
      expect(save_card_decision.fallback_reason).to eq(:future_charge_setup)
    end

    it "withholds the method for off-session charges" do
      off_session_decision = described_class.new(order:,
                                                 seller:,
                                                 merchant_account:,
                                                 chargeable:,
                                                 purchases:,
                                                 params:,
                                                 setup_future_charges:,
                                                 off_session: true).method_forced_decision(payment_method:)

      expect(off_session_decision).not_to be_eligible
      expect(off_session_decision.fallback_reason).to eq(:off_session)
    end

    it "withholds the method for multi-item checkouts" do
      purchases << create(:purchase, link: product, seller:, merchant_account:, purchase_state: "in_progress")

      expect(forced_decision).not_to be_eligible
      expect(forced_decision.fallback_reason).to eq(:multi_item_checkout)
    end

    it "withholds the method for installment payments" do
      purchase.update!(is_installment_payment: true)

      expect(forced_decision).not_to be_eligible
      expect(forced_decision.fallback_reason).to eq(:unsupported_product_type)
    end

    it "withholds the method for products priced in a third currency that is neither USD nor the forced one" do
      purchase.update!(link: create(:product, user: seller, price_currency_type: Currency::GBP))

      expect(forced_decision).not_to be_eligible
      expect(forced_decision.fallback_reason).to eq(:unsupported_product_currency)
    end

    it "withholds the method when the forced currency's minor units differ between Gumroad and Stripe" do
      stub_const("#{described_class}::FORCED_CURRENCY_PAYMENT_METHODS",
                 described_class::FORCED_CURRENCY_PAYMENT_METHODS.merge("krw_only_method" => Currency::KRW))

      krw_decision = described_class.new(order:,
                                         seller:,
                                         merchant_account:,
                                         chargeable:,
                                         purchases:,
                                         params:,
                                         setup_future_charges:,
                                         off_session:).method_forced_decision(payment_method: "krw_only_method")

      expect(krw_decision).not_to be_eligible
      expect(krw_decision.fallback_reason).to eq(:unsupported_forced_currency)
    end
  end
end
