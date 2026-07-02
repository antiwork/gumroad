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

  it "falls back in live mode" do
    allow(Stripe).to receive(:api_key).and_return("sk_live_currency")

    expect(decision).not_to be_eligible
    expect(decision.fallback_reason).to eq(:live_mode)
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
end
