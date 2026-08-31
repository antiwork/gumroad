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
    Feature.deactivate_user(described_class::LISTED_CURRENCY_DIRECT_CHARGE_FEATURE_NAME, seller)
    Feature.deactivate_user(described_class::SUBSCRIPTION_FEATURE_NAME, seller)
    Feature.deactivate_user(StripeChargeProcessor::INDIA_CARD_MANDATE_RELIABILITY_FEATURE, seller)
  end

  it "allows the PR1 Stripe test-mode direct-charge path" do
    expect(decision).to be_eligible
    expect(decision.currency).to eq(Currency::CAD)
    expect(decision.fallback_reason).to be_nil
  end

  it "gates on the currency the submitted quote token confirmed, not GeoIP" do
    token = Rails.application.message_verifier(:buyer_currency_quote).generate({ currency: Currency::GBP })

    picked_decision = described_class.new(order:,
                                          seller:,
                                          merchant_account:,
                                          chargeable:,
                                          purchases:,
                                          params: { buyer_currency_quote: token },
                                          setup_future_charges:,
                                          off_session:).decision

    expect(picked_decision).to be_eligible
    expect(picked_decision.currency).to eq(Currency::GBP)
  end

  it "falls back to GeoIP when the submitted quote token is tampered" do
    tampered_decision = described_class.new(order:,
                                            seller:,
                                            merchant_account:,
                                            chargeable:,
                                            purchases:,
                                            params: { buyer_currency_quote: "not-a-signed-token" },
                                            setup_future_charges:,
                                            off_session:).decision

    expect(tampered_decision).to be_eligible
    expect(tampered_decision.currency).to eq(Currency::CAD)
  end

  it "allows the PR1 Stripe test-mode Gumroad platform-account path" do
    platform_merchant_account = create(
      :merchant_account,
      user: nil,
      charge_processor_id: StripeChargeProcessor.charge_processor_id,
      charge_processor_merchant_id: "acct_buyer_currency_platform",
      currency: Currency::USD
    )
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

  context "with India card mandate reliability enabled for a membership" do
    let(:product) { create(:subscription_product, user: seller, price_currency_type: Currency::USD) }

    before do
      Feature.activate_user(described_class::SUBSCRIPTION_FEATURE_NAME, seller)
      Feature.activate_user(StripeChargeProcessor::INDIA_CARD_MANDATE_RELIABILITY_FEATURE, seller)
      allow_any_instance_of(described_class).to receive(:buyer_currency_for_ip).and_return(Currency::AUD)
    end

    it "falls back before quoting an unsupported platform mandate currency" do
      platform_merchant_account = create(
        :merchant_account,
        user: nil,
        currency: Currency::USD,
        charge_processor_merchant_id: "acct_india_mandate_eligibility"
      )
      purchase.update!(merchant_account: platform_merchant_account)

      platform_decision = described_class.new(
        order:,
        seller:,
        merchant_account: platform_merchant_account,
        chargeable:,
        purchases:,
        params:,
        setup_future_charges:,
        off_session:
      ).decision

      expect(platform_decision).not_to be_eligible
      expect(platform_decision.fallback_reason).to eq(:unsupported_indian_card_mandate_currency)
    end

    it "keeps direct Connect outside the mandate currency gate" do
      expect(decision).to be_eligible
      expect(decision.currency).to eq(Currency::AUD)
    end
  end

  it "falls back when the internal rollout flag is disabled" do
    Feature.deactivate_user(described_class::FEATURE_NAME, seller)

    expect(decision).not_to be_eligible
    expect(decision.fallback_reason).to eq(:feature_disabled)
  end

  describe ".seller_enabled?" do
    it "stays off when the seller hides buyer-local currency" do
      seller.update!(disable_buyer_local_currency: true)

      expect(described_class.seller_enabled?(seller)).to eq(false)
    end

    it "is off when either charging flag is off" do
      Feature.deactivate_user(described_class::FEATURE_NAME, seller)

      expect(described_class.seller_enabled?(seller)).to eq(false)
    end
  end

  it "stays eligible in live mode now that the card presentment path has shipped its safety gates" do
    allow(Stripe).to receive(:api_key).and_return("sk_live_currency")

    expect(decision).to be_eligible
    expect(decision.currency).to eq(Currency::CAD)
    expect(decision.fallback_reason).to be_nil
  end

  it "falls back without an FX-quote round trip when a settlement-currency mismatch was recorded for the buyer's currency" do
    # The stored currency still says usd for accounts with Stripe multi-currency
    # settlement — the recorded marker from a previously rejected FX quote is what tells
    # checkout the quote call is doomed (issue #6011).
    merchant_account.record_settlement_currency_mismatch!(Currency::CAD)

    expect(decision).not_to be_eligible
    expect(decision.fallback_reason).to eq(:unsupported_settlement_currency)
  end

  it "stays eligible when the recorded mismatch is for a different currency" do
    # Stripe settlement is configured per currency (gumroad-private#933, 2026-07-22): a
    # EUR mismatch must not suppress quoting for this CAD buyer.
    merchant_account.record_settlement_currency_mismatch!("eur")

    expect(decision).to be_eligible
    expect(decision.fallback_reason).to be_nil
  end

  it "regains eligibility once a recorded settlement-currency mismatch expires" do
    merchant_account.update!(settlement_currency_mismatch_noticed_at: (MerchantAccount::SETTLEMENT_CURRENCY_MISMATCH_TTL + 1.day).ago.iso8601)

    expect(decision).to be_eligible
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

  it "falls back for recurring-billing products even when a quote token matched seller, currency, and total" do
    # The quote token binds only seller, currency, and total — not product ids — so the
    # charge path must reject the same product shapes the quote refuses to lock.
    membership = create(:membership_product, user: seller, price_currency_type: Currency::USD)
    purchase.update!(link: membership)

    expect(decision).not_to be_eligible
    expect(decision.fallback_reason).to eq(:unsupported_product_type)
  end

  it "falls back for products in a preorder state" do
    product.update!(is_in_preorder_state: true)

    expect(decision).not_to be_eligible
    expect(decision.fallback_reason).to eq(:unsupported_product_type)
  end

  it "allows products in a preorder state when the later-charge ramp is enabled" do
    Feature.activate_user(described_class::SUBSCRIPTION_FEATURE_NAME, seller)
    product.update!(is_in_preorder_state: true)

    expect(decision).to be_eligible
    expect(decision.fallback_reason).to be_nil
  end

  it "falls back for free-trial products" do
    free_trial_product = create(:membership_product, :with_free_trial_enabled, user: seller, price_currency_type: Currency::USD)
    purchase.update!(link: free_trial_product)

    expect(decision).not_to be_eligible
    expect(decision.fallback_reason).to eq(:unsupported_product_type)
  end

  it "allows pay-in-full purchases of products offering an installment plan" do
    installment_product = create(:product, user: seller, price_cents: 9_00, price_currency_type: Currency::USD)
    create(:product_installment_plan, link: installment_product, number_of_installments: 3)
    purchase.update!(link: installment_product.reload)

    expect(decision).to be_eligible
    expect(decision.fallback_reason).to be_nil
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

  # Wallet payments are accepted, but only from the surface whose sheet quotes the locked
  # buyer-currency total (the Payment Element) and only while the seller is in both wallet
  # rollout flags. The Payment Request Button's sheet is built from the canonical USD total,
  # and it cannot reach a presentment checkout today anyway — it is suppressed whenever the
  # Payment Element renders wallets (PaymentForm.tsx passes `disable_wallets ||
  # payment_element_wallets` as its disabled flag), and selecting it sets checkout's
  # paymentMethod to "stripePaymentRequest", which makes getCheckoutBuyerCurrencyDisplay
  # return null so no quote token is issued. The gate below is the server-side backstop for
  # both rules, so pulling a flag stops in-flight wallet charges instead of only removing the
  # rows from newly rendered pages.
  context "wallet payments" do
    before do
      Feature.activate_user(described_class::PAYMENT_ELEMENT_WALLETS_FEATURE_NAME, seller)
      Feature.activate_user(described_class::WALLETS_FEATURE_NAME, seller)
      params[:wallet_type] = "apple_pay"
      params[:payment_details_source] = PurchasePaymentFlow::PAYMENT_ELEMENT
    end

    after do
      Feature.deactivate_user(described_class::PAYMENT_ELEMENT_WALLETS_FEATURE_NAME, seller)
      Feature.deactivate_user(described_class::WALLETS_FEATURE_NAME, seller)
    end

    it "allows a Payment Element wallet payment when both rollout flags are active" do
      expect(decision).to be_eligible
      expect(decision.currency).to eq(Currency::CAD)
      expect(decision.fallback_reason).to be_nil
    end

    it "refuses the wallet payment once the lane's ramp flag is pulled" do
      Feature.deactivate_user(described_class::WALLETS_FEATURE_NAME, seller)

      expect(decision).not_to be_eligible
      expect(decision.fallback_reason).to eq(:wallet_payment_request)
    end

    it "refuses the wallet payment once the general wallet flag is pulled" do
      Feature.deactivate_user(described_class::PAYMENT_ELEMENT_WALLETS_FEATURE_NAME, seller)

      expect(decision).not_to be_eligible
      expect(decision.fallback_reason).to eq(:wallet_payment_request)
    end

    it "refuses a wallet payment that does not come from the Payment Element" do
      params[:payment_details_source] = nil

      expect(decision).not_to be_eligible
      expect(decision.fallback_reason).to eq(:wallet_payment_request)
    end

    it "still allows a non-wallet payment when the wallet flags are off" do
      Feature.deactivate_user(described_class::WALLETS_FEATURE_NAME, seller)
      params[:wallet_type] = nil

      expect(decision).to be_eligible
      expect(decision.fallback_reason).to be_nil
    end
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

  it "allows multi-item checkouts when all purchases come from one seller" do
    second_purchase = create(:purchase,
                             link: create(:product, user: seller, price_currency_type: Currency::USD),
                             seller:,
                             merchant_account:,
                             purchase_state: "in_progress",
                             ip_address: "203.0.113.1")
    purchases << second_purchase
    order.purchases << purchase
    order.purchases << second_purchase

    expect(decision).to be_eligible
    expect(decision.currency).to eq(Currency::CAD)
    expect(decision.fallback_reason).to be_nil
  end

  context "with an order spanning several sellers" do
    # ChargeService creates one charge per seller, so this service only ever sees one
    # seller's purchases — the multi-seller signal lives on the order.
    let(:other_seller) { create(:user) }
    let!(:other_seller_purchase) do
      create(:purchase,
             link: create(:product, user: other_seller),
             seller: other_seller,
             purchase_state: "in_progress")
    end

    before do
      order.purchases << purchase
      order.purchases << other_seller_purchase
    end

    it "is eligible for every charge a multi-seller order produces" do
      # Each charge is priced from its own entry in the quote token, locked before the buyer
      # saw a total, so nothing needs splitting across intents.
      expect(decision).to be_eligible
      expect(decision.currency).to eq(Currency::CAD)
    end

    it "is eligible for the off-session charge a multi-seller cart performs" do
      # A multi-seller checkout charges off-session by design: the browser collects a reusable
      # payment method once and each seller's charge is confirmed against it server-side. The
      # buyer is present for that, so presentment is safe — unlike a renewal months later.
      decision = described_class.new(order:, seller:, merchant_account:, chargeable:, purchases:, params:,
                                     setup_future_charges: false, off_session: true).decision

      expect(decision).to be_eligible
    end
  end

  it "allows a purchase priced in a currency that is neither USD nor the buyer's own" do
    purchase.update!(link: create(:product, user: seller, price_currency_type: Currency::EUR))

    expect(decision).to be_eligible
    expect(decision.currency).to eq(Currency::CAD)
  end

  def report_listed_currency_element(params, currency = Currency::CAD)
    params[:payment_details_source] = PurchasePaymentFlow::PAYMENT_ELEMENT
    params[:payment_element_mount_currency] = currency
  end

  it "falls back when a purchase is priced in the buyer's own currency while direct listed charging is off" do
    report_listed_currency_element(params)
    purchase.update!(link: create(:product, user: seller, price_currency_type: Currency::CAD))

    expect(decision).not_to be_eligible
    expect(decision.fallback_reason).to eq(:listed_currency_is_buyer_currency)
  end

  it "allows direct listed charging when the purchase is priced in the buyer's own currency" do
    Feature.activate_user(described_class::LISTED_CURRENCY_DIRECT_CHARGE_FEATURE_NAME, seller)
    report_listed_currency_element(params)
    purchase.update!(link: create(:product, user: seller, price_currency_type: Currency::CAD),
                     displayed_price_currency_type: Currency::CAD,
                     rate_converted_to_usd: "0.8")

    expect(decision).to be_eligible
    expect(decision.currency).to eq(Currency::CAD)
    expect(decision.direct_listed_amount?).to eq(true)
  end

  it "allows direct listed charging for a multi-item cart uniformly priced in the buyer's currency" do
    Feature.activate_user(described_class::LISTED_CURRENCY_DIRECT_CHARGE_FEATURE_NAME, seller)
    report_listed_currency_element(params)
    purchase.update!(link: create(:product, user: seller, price_currency_type: Currency::CAD),
                     displayed_price_currency_type: Currency::CAD,
                     rate_converted_to_usd: "0.8")
    second_purchase = create(:purchase,
                             link: create(:product, user: seller, price_currency_type: Currency::CAD),
                             seller:,
                             merchant_account:,
                             purchase_state: "in_progress",
                             ip_address: "203.0.113.1")
    second_purchase.update!(displayed_price_currency_type: Currency::CAD,
                            rate_converted_to_usd: "0.8")
    purchases << second_purchase

    expect(decision).to be_eligible
    expect(decision.currency).to eq(Currency::CAD)
    expect(decision.direct_listed_amount?).to eq(true)
  end

  it "falls back from the listed lane when the order spans another seller" do
    Feature.activate_user(described_class::LISTED_CURRENCY_DIRECT_CHARGE_FEATURE_NAME, seller)
    report_listed_currency_element(params)
    purchase.update!(link: create(:product, user: seller, price_currency_type: Currency::CAD),
                     displayed_price_currency_type: Currency::CAD,
                     rate_converted_to_usd: "0.8")
    other_seller = create(:user)
    order.purchases << purchase
    order.purchases << create(:purchase,
                              link: create(:product, user: other_seller, price_currency_type: Currency::CAD),
                              seller: other_seller,
                              purchase_state: "in_progress",
                              ip_address: "203.0.113.1",
                              displayed_price_currency_type: Currency::CAD,
                              rate_converted_to_usd: "0.8")

    expect(decision).not_to be_eligible
    expect(decision.fallback_reason).to eq(:listed_currency_is_buyer_currency)
  end

  it "falls back from the listed lane when the charge purchases belong to more than one seller" do
    Feature.activate_user(described_class::LISTED_CURRENCY_DIRECT_CHARGE_FEATURE_NAME, seller)
    report_listed_currency_element(params)
    purchase.update!(link: create(:product, user: seller, price_currency_type: Currency::CAD),
                     displayed_price_currency_type: Currency::CAD,
                     rate_converted_to_usd: "0.8")
    other_seller = create(:user)
    purchases << create(:purchase,
                        link: create(:product, user: other_seller, price_currency_type: Currency::CAD),
                        seller: other_seller,
                        merchant_account:,
                        purchase_state: "in_progress",
                        ip_address: "203.0.113.1",
                        displayed_price_currency_type: Currency::CAD,
                        rate_converted_to_usd: "0.8")

    expect(decision).not_to be_eligible
    expect(decision.fallback_reason).to eq(:listed_currency_is_buyer_currency)
  end

  it "falls back from the listed lane when same-currency purchases have split conversion rates" do
    Feature.activate_user(described_class::LISTED_CURRENCY_DIRECT_CHARGE_FEATURE_NAME, seller)
    report_listed_currency_element(params)
    purchase.update!(link: create(:product, user: seller, price_currency_type: Currency::CAD),
                     displayed_price_currency_type: Currency::CAD,
                     rate_converted_to_usd: "0.8")
    purchases << create(:purchase,
                        link: create(:product, user: seller, price_currency_type: Currency::CAD),
                        seller:,
                        merchant_account:,
                        purchase_state: "in_progress",
                        ip_address: "203.0.113.1",
                        displayed_price_currency_type: Currency::CAD,
                        rate_converted_to_usd: "0.9")

    expect(decision).not_to be_eligible
    expect(decision.fallback_reason).to eq(:listed_currency_is_buyer_currency)
  end

  it "falls back when checkout did not mount the listed-currency Payment Element" do
    Feature.activate_user(described_class::LISTED_CURRENCY_DIRECT_CHARGE_FEATURE_NAME, seller)
    purchase.update!(link: create(:product, user: seller, price_currency_type: Currency::CAD),
                     displayed_price_currency_type: Currency::CAD,
                     rate_converted_to_usd: "0.8")

    expect(decision).not_to be_eligible
    expect(decision.fallback_reason).to eq(:listed_currency_is_buyer_currency)
  end

  it "allows the client-confirm prepare path without a server-side chargeable" do
    Feature.activate_user(described_class::LISTED_CURRENCY_DIRECT_CHARGE_FEATURE_NAME, seller)
    report_listed_currency_element(params)
    purchase.update!(link: create(:product, user: seller, price_currency_type: Currency::CAD),
                     displayed_price_currency_type: Currency::CAD,
                     rate_converted_to_usd: "0.8")

    client_confirm_decision = described_class.new(order:,
                                                  seller:,
                                                  merchant_account:,
                                                  chargeable: nil,
                                                  purchases:,
                                                  params:,
                                                  setup_future_charges: false,
                                                  off_session: false,
                                                  client_confirm: true).decision

    expect(client_confirm_decision).to be_eligible
    expect(client_confirm_decision.direct_listed_amount?).to eq(true)
  end

  it "falls back when the product was repriced into the buyer's currency after the purchase was built" do
    Feature.activate_user(described_class::LISTED_CURRENCY_DIRECT_CHARGE_FEATURE_NAME, seller)
    report_listed_currency_element(params)
    purchase.update!(link: create(:product, user: seller, price_currency_type: Currency::CAD),
                     displayed_price_currency_type: Currency::USD)

    expect(decision).not_to be_eligible
    expect(decision.fallback_reason).to eq(:listed_currency_is_buyer_currency)
  end

  it "quotes a mixed cart of a buyer-currency listing and a USD listing" do
    Feature.activate_user(described_class::LISTED_CURRENCY_DIRECT_CHARGE_FEATURE_NAME, seller)
    report_listed_currency_element(params)
    purchase.update!(link: create(:product, user: seller, price_currency_type: Currency::CAD))
    purchases << create(:purchase,
                        link: create(:product, user: seller, price_currency_type: Currency::USD),
                        seller:,
                        merchant_account:,
                        purchase_state: "in_progress",
                        ip_address: "203.0.113.1")

    expect(decision).to be_eligible
    expect(decision.currency).to eq(Currency::CAD)
    expect(decision.direct_listed_amount?).to eq(false)
  end

  it "keeps earlier fallbacks ahead of direct listed charging" do
    Feature.activate_user(described_class::LISTED_CURRENCY_DIRECT_CHARGE_FEATURE_NAME, seller)
    report_listed_currency_element(params)
    purchase.update!(link: create(:product, user: seller, price_currency_type: Currency::CAD))

    off_session_decision = described_class.new(order:,
                                               seller:,
                                               merchant_account:,
                                               chargeable:,
                                               purchases:,
                                               params:,
                                               setup_future_charges: false,
                                               off_session: true).decision

    expect(off_session_decision).not_to be_eligible
    expect(off_session_decision.fallback_reason).to eq(:off_session)
  end

  it "falls back for a membership priced in the buyer's currency, whose renewals have no stored presentment" do
    Feature.activate_user(described_class::LISTED_CURRENCY_DIRECT_CHARGE_FEATURE_NAME, seller)
    report_listed_currency_element(params)
    Feature.activate_user(described_class::SUBSCRIPTION_FEATURE_NAME, seller)
    membership = create(:membership_product, user: seller, price_currency_type: Currency::CAD)
    purchase.update!(link: membership,
                     displayed_price_currency_type: Currency::CAD,
                     is_original_subscription_purchase: true,
                     subscription: create(:subscription, link: membership, user: purchase.purchaser))

    expect(decision).not_to be_eligible
    expect(decision.fallback_reason).to eq(:listed_currency_is_buyer_currency)
  ensure
    Feature.deactivate_user(described_class::SUBSCRIPTION_FEATURE_NAME, seller)
  end

  it "allows direct listed charging when a buyer-currency purchase carries a tip" do
    Feature.activate_user(described_class::LISTED_CURRENCY_DIRECT_CHARGE_FEATURE_NAME, seller)
    report_listed_currency_element(params)
    purchase.update!(link: create(:product, user: seller, price_currency_type: Currency::CAD),
                     displayed_price_currency_type: Currency::CAD,
                     rate_converted_to_usd: "0.8")
    create(:tip, purchase:, value_cents: 200)

    expect(decision).to be_eligible
    expect(decision.currency).to eq(Currency::CAD)
    expect(decision.direct_listed_amount?).to eq(true)
  end

  it "falls back when a buyer-currency purchase carries shipping" do
    # Shipping conversion now matches surcharge vs charge, but the direct-listed Element still
    # has no listed-currency shipping basis. Eligibility must stay aligned with that mount path.
    Feature.activate_user(described_class::LISTED_CURRENCY_DIRECT_CHARGE_FEATURE_NAME, seller)
    report_listed_currency_element(params)
    purchase.update!(link: create(:product, user: seller, price_currency_type: Currency::CAD),
                     displayed_price_currency_type: Currency::CAD,
                     shipping_cents: 300)

    expect(decision).not_to be_eligible
    expect(decision.fallback_reason).to eq(:listed_currency_is_buyer_currency)
  end

  it "does not apply the FX-quote settlement gate to direct listed charging" do
    Feature.activate_user(described_class::LISTED_CURRENCY_DIRECT_CHARGE_FEATURE_NAME, seller)
    report_listed_currency_element(params)
    merchant_account.record_settlement_currency_mismatch!(Currency::CAD)
    purchase.update!(link: create(:product, user: seller, price_currency_type: Currency::CAD),
                     displayed_price_currency_type: Currency::CAD,
                     rate_converted_to_usd: "0.8")

    expect(decision).to be_eligible
    expect(decision.direct_listed_amount?).to eq(true)
  end

  it "falls back when any purchase on the charge is an installment payment" do
    second_purchase = create(:purchase,
                             link: create(:product, user: seller, price_currency_type: Currency::USD),
                             seller:,
                             merchant_account:,
                             purchase_state: "in_progress",
                             ip_address: "203.0.113.1")
    second_purchase.update!(is_installment_payment: true)
    purchases << second_purchase

    expect(decision).not_to be_eligible
    expect(decision.fallback_reason).to eq(:unsupported_product_type)
  end

  it "falls back for seller-managed destination-charge models" do
    merchant_account.update!(json_data: {})

    expect(decision).not_to be_eligible
    expect(decision.fallback_reason).to eq(:unsupported_charge_model)
  end

  describe "destination charges" do
    # A Gumroad-managed Stripe Custom account: it belongs to a user (so it is not the
    # platform row) but it is not a Stripe Connect account either, so Stripe charges it
    # with a destination charge — the PaymentIntent is created on the platform account and
    # this account receives transfer_data[destination].
    let(:merchant_account) { create(:merchant_account, user: seller, currency: Currency::USD) }
    # MerchantAccount.gumroad is the platform row (the one with no user). It is normally
    # seeded in the test database; create it when a fresh database has not been seeded, so
    # the lookup the production code makes finds the same row these examples assert on.
    let!(:platform_merchant_account) do
      MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id)&.tap do |account|
        account.update!(charge_processor_merchant_id: "acct_gumroad_platform", currency: Currency::USD)
      end || create(:merchant_account, user: nil, charge_processor_merchant_id: "acct_gumroad_platform", currency: Currency::USD)
    end

    it "falls back while the destination-charge ramp flag is off" do
      expect(decision).not_to be_eligible
      expect(decision.fallback_reason).to eq(:unsupported_charge_model)
    end

    it "still routes the quote to the platform account while the ramp flag is off" do
      # The ramp flag decides whether the CARD lane may quote a destination charge at all.
      # It cannot decide WHICH account a quote is minted on: the forced-currency lane
      # (iDEAL/Bancontact/UPI/Pix) already accepts destination charges regardless of this
      # flag, and its intent is created on the platform account either way. Returning the
      # seller's account here would mint that lane's quote in a different account from its
      # intent, which Stripe rejects.
      expect(described_class.fx_quote_merchant_account(merchant_account)).to eq(platform_merchant_account)
    end

    it "declares the seller's account as the quote's transfer destination" do
      # A destination charge's intent carries transfer_data[destination], and Stripe refuses
      # a quote that does not name the same account, so the quote and the intent have to
      # agree on the destination as well as on which account mints the quote.
      expect(described_class.fx_quote_destination_account_id(merchant_account))
        .to eq(merchant_account.charge_processor_merchant_id)
    end

    it "declares the transfer destination regardless of the ramp flag" do
      # Same reason the account routing is not flag-gated: whether the intent carries a
      # transfer is a fact about how Stripe creates it, and the forced-currency lane creates
      # destination charges with the flag off.
      Feature.activate_user(described_class::DESTINATION_CHARGE_FEATURE_NAME, seller)
      expect(described_class.fx_quote_destination_account_id(merchant_account))
        .to eq(merchant_account.charge_processor_merchant_id)
    ensure
      Feature.deactivate_user(described_class::DESTINATION_CHARGE_FEATURE_NAME, seller)
    end

    context "with the destination-charge ramp flag on" do
      before { Feature.activate_user(described_class::DESTINATION_CHARGE_FEATURE_NAME, seller) }
      after { Feature.deactivate_user(described_class::DESTINATION_CHARGE_FEATURE_NAME, seller) }

      it "is eligible" do
        expect(decision).to be_eligible
        expect(decision.currency).to eq(Currency::CAD)
        expect(decision.fallback_reason).to be_nil
      end

      it "quotes against the platform account, which is where the intent is created" do
        expect(described_class.fx_quote_merchant_account(merchant_account)).to eq(platform_merchant_account)
      end

      it "stays eligible when the seller's own account settles in a non-USD currency" do
        # The charge converts the buyer's currency to the PLATFORM's settlement currency;
        # the seller's euros come from the later transfer, which no FX quote covers.
        merchant_account.update!(currency: Currency::EUR)

        expect(decision).to be_eligible
        expect(decision.currency).to eq(Currency::CAD)
      end

      it "falls back when the PLATFORM account settles the buyer's currency in itself" do
        platform_merchant_account.record_settlement_currency_mismatch!(Currency::CAD)

        expect(decision).not_to be_eligible
        expect(decision.fallback_reason).to eq(:unsupported_settlement_currency)
      end

      it "ignores a mismatch marker on the seller's own account" do
        # The seller's account never mints the quote for this charge model, so a marker
        # learned there says nothing about whether this charge can be quoted.
        merchant_account.record_settlement_currency_mismatch!(Currency::CAD)

        expect(decision).to be_eligible
      end
    end
  end

  describe "direct charges" do
    it "sends no transfer destination, because a direct charge carries no transfer" do
      # A direct charge is created on the seller's own connected account and pays them
      # directly, so the intent has no transfer_data — and a quote that named a destination
      # would be refused on it.
      expect(described_class.fx_quote_destination_account_id(merchant_account)).to be_nil
    end

    it "still quotes against the seller's own connected account" do
      # A direct charge creates the intent on the seller's account, so nothing about the
      # destination lane may move the quote off it — with the ramp flag on or off.
      expect(described_class.fx_quote_merchant_account(merchant_account)).to eq(merchant_account)

      Feature.activate_user(described_class::DESTINATION_CHARGE_FEATURE_NAME, seller)
      expect(described_class.fx_quote_merchant_account(merchant_account)).to eq(merchant_account)
    ensure
      Feature.deactivate_user(described_class::DESTINATION_CHARGE_FEATURE_NAME, seller)
    end

    it "still falls back when the seller's own account settles the buyer's currency in itself" do
      merchant_account.record_settlement_currency_mismatch!(Currency::CAD)

      expect(decision).not_to be_eligible
      expect(decision.fallback_reason).to eq(:unsupported_settlement_currency)
    end
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

    it "allows UPI in INR" do
      upi_decision = described_class.new(order:,
                                         seller:,
                                         merchant_account:,
                                         chargeable:,
                                         purchases:,
                                         params:,
                                         setup_future_charges:,
                                         off_session:).method_forced_decision(payment_method: "upi")

      expect(upi_decision).to be_eligible
      expect(upi_decision.currency).to eq(Currency::INR)
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

    it "does not let the UPI launch flag launch EUR methods in live mode" do
      allow(Stripe).to receive(:api_key).and_return("sk_live_currency")
      Feature.activate_user(:checkout_local_method_upi, seller)

      expect(forced_decision).not_to be_eligible
      expect(forced_decision.fallback_reason).to eq(:method_not_launched)
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

    # The Gumroad platform account is the account a destination charge's PaymentIntent is
    # created on, so the three destination-charge tests below need it to exist. It is a
    # seeded row in most environments; create it here so the file is self-contained.
    def platform_merchant_account
      MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id) ||
        create(:merchant_account, user: nil, charge_processor_id: StripeChargeProcessor.charge_processor_id,
                                  charge_processor_merchant_id: nil, country: "US", currency: Currency::USD)
    end

    # Superseded by gumroad-private#1409. A Gumroad-managed seller account IS a
    # destination-charge model: the PaymentIntent is created on the Gumroad platform
    # account with the seller's account as transfer_data[destination] — the same intent
    # shape as a seller with no Stripe account at all, which this lane has always
    # supported. Withholding it only hid local payment methods from checkouts that could
    # complete. The card lane's own charge-model gate is unchanged (it mints an FX quote
    # against the seller's account, where the model genuinely matters).
    it "allows the method for a seller-managed destination-charge model" do
      platform_merchant_account
      merchant_account.update!(json_data: {}, currency: Currency::USD)
      purchase.update!(link: create(:product, user: seller, price_currency_type: Currency::EUR))

      expect(forced_decision).to be_eligible
      expect(forced_decision.currency).to eq(Currency::EUR)
    end

    # gumroad-private#1442. A product priced in the method's forced currency is charged
    # at its listed price with no FX quote, so the charging account's own balance
    # currency has no bearing on whether the charge can succeed — a EUR intent on a
    # EUR-settling Belgian account is the most natural shape there is. Requiring US
    # dollars here withheld iDEAL and Bancontact from most eurozone sellers.
    it "allows the method for merchant accounts that settle in a non-USD currency when the product is priced in the forced currency" do
      purchase.update!(link: create(:product, user: seller, price_currency_type: Currency::EUR))
      merchant_account.update!(currency: Currency::EUR)

      expect(forced_decision).to be_eligible
      expect(forced_decision.currency).to eq(Currency::EUR)
      expect(forced_decision.direct_listed_amount?).to eq(true)
    end

    it "allows the method for a merchant account settling in a third currency, unrelated to the forced one" do
      purchase.update!(link: create(:product, user: seller, price_currency_type: Currency::EUR))
      merchant_account.update!(currency: Currency::CAD)

      expect(forced_decision).to be_eligible
      expect(forced_decision.currency).to eq(Currency::EUR)
    end

    # gumroad-private#1409. The default merchant_account in this spec is a Stripe Connect
    # (direct-charge) account. A destination-charge seller is different: the intent is
    # created on the Gumroad platform account and their own account merely receives the
    # transfer afterwards.
    it "keeps the method available for a destination-charge seller whose own account settles in a non-USD currency" do
      platform_merchant_account.update!(currency: Currency::USD)
      destination_merchant_account = create(:merchant_account, user: seller, charge_processor_id: StripeChargeProcessor.charge_processor_id, currency: Currency::GBP, country: "GB")
      purchase.update!(link: create(:product, user: seller, price_currency_type: Currency::INR, price_cents: 81_800_00), merchant_account: destination_merchant_account)

      upi_decision = described_class.new(order:,
                                         seller:,
                                         merchant_account: destination_merchant_account,
                                         chargeable:,
                                         purchases:,
                                         params:,
                                         setup_future_charges:,
                                         off_session:).method_forced_decision(payment_method: "upi")

      expect(upi_decision).to be_eligible
      expect(upi_decision.currency).to eq(Currency::INR)
      expect(upi_decision.direct_listed_amount?).to eq(true)
    end

    it "keeps the method available when the Gumroad platform account the destination charge is created on holds a non-USD balance" do
      platform_merchant_account.update!(currency: Currency::CAD)
      destination_merchant_account = create(:merchant_account, user: seller, charge_processor_id: StripeChargeProcessor.charge_processor_id, currency: Currency::USD)
      purchase.update!(link: create(:product, user: seller, price_currency_type: Currency::EUR), merchant_account: destination_merchant_account)

      destination_decision = described_class.new(order:,
                                                 seller:,
                                                 merchant_account: destination_merchant_account,
                                                 chargeable:,
                                                 purchases:,
                                                 params:,
                                                 setup_future_charges:,
                                                 off_session:).method_forced_decision(payment_method:)

      expect(destination_decision).to be_eligible
      expect(destination_decision.currency).to eq(Currency::EUR)
    end

    # Regression test for the 2026-07-23 iDEAL dark-ramp (gumroad-private#933): enabling
    # the iDEAL/SEPA capabilities makes the account settle EUR in EUR, so an EUR
    # mismatch marker is the EXPECTED steady state for exactly the accounts that can
    # take iDEAL. The direct-listed-amount lane charges the listed EUR price without an
    # FX quote, so the marker must not withhold the method there.
    it "keeps the method available for a product priced in the forced currency when the mismatch marker is set for that currency" do
      purchase.update!(link: create(:product, user: seller, price_currency_type: Currency::EUR))
      merchant_account.record_settlement_currency_mismatch!(Currency::EUR)

      expect(forced_decision).to be_eligible
      expect(forced_decision.currency).to eq(Currency::EUR)
      expect(forced_decision.direct_listed_amount?).to eq(true)
    end

    it "withholds the method for a USD-priced product when the mismatch marker is set for the forced currency — the FX quote it needs would be rejected" do
      merchant_account.record_settlement_currency_mismatch!(Currency::EUR)

      expect(forced_decision).not_to be_eligible
      expect(forced_decision.fallback_reason).to eq(:unsupported_settlement_currency)
    end

    it "keeps the USD-priced quote path available when the recorded mismatch is for a different currency" do
      merchant_account.record_settlement_currency_mismatch!(Currency::GBP)

      expect(forced_decision).to be_eligible
      expect(forced_decision.direct_listed_amount?).to eq(false)
    end

    # The quoted (USD-priced) case still asks BOTH halves of the settlement question, and
    # this pins the half that does not depend on a learned mismatch marker: an account
    # whose stored balance currency is not US dollars cannot be quoted from the forced
    # currency into USD, so the method has to stay withheld there even though the
    # direct-listed lane above no longer cares about the same account's currency.
    it "withholds the method for a USD-priced product when the account holds a non-USD balance and no mismatch marker is set" do
      merchant_account.update!(currency: Currency::EUR)

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

    it "allows the direct listed-amount path for multi-item carts uniformly priced in the forced currency" do
      purchase.update!(link: create(:product, user: seller, price_currency_type: Currency::INR, price_cents: 7300))
      purchases << create(:purchase,
                          link: create(:product, user: seller, price_currency_type: Currency::INR, price_cents: 7300),
                          seller:,
                          merchant_account:,
                          purchase_state: "in_progress")

      upi_decision = described_class.new(order:,
                                         seller:,
                                         merchant_account:,
                                         chargeable:,
                                         purchases:,
                                         params:,
                                         setup_future_charges:,
                                         off_session:).method_forced_decision(payment_method: "upi")

      expect(upi_decision).to be_eligible
      expect(upi_decision.currency).to eq(Currency::INR)
      expect(upi_decision.direct_listed_amount?).to eq(true)
    end

    it "withholds the method for multi-item carts that need the per-line quote basis" do
      purchase.update!(link: create(:product, user: seller, price_currency_type: Currency::INR, price_cents: 7300))
      purchases << create(:purchase, link: product, seller:, merchant_account:, purchase_state: "in_progress")

      upi_decision = described_class.new(order:,
                                         seller:,
                                         merchant_account:,
                                         chargeable:,
                                         purchases:,
                                         params:,
                                         setup_future_charges:,
                                         off_session:).method_forced_decision(payment_method: "upi")

      expect(upi_decision).not_to be_eligible
      expect(upi_decision.fallback_reason).to eq(:unsupported_product_currency)
    end

    # A single USD-priced line is allowed through here on the quoted-FX path, and that
    # allowance is deliberately narrow: two USD lines would need one quote per line before the
    # quoted amounts could reconcile with the persisted purchase rows. Pin the boundary so
    # widening the single-line allowance can't silently let a multi-line USD cart in.
    it "withholds the method for multi-item USD carts, which would need one quote per line" do
      purchases << create(:purchase, link: product, seller:, merchant_account:, purchase_state: "in_progress")

      expect(product.price_currency_type.to_s).to eq(Currency::USD)
      expect(forced_decision).not_to be_eligible
      expect(forced_decision.fallback_reason).to eq(:unsupported_product_currency)
    end

    it "withholds the method when the charge has no purchases" do
      empty_decision = described_class.new(order:,
                                           seller:,
                                           merchant_account:,
                                           chargeable:,
                                           purchases: [],
                                           params:,
                                           setup_future_charges:,
                                           off_session:).method_forced_decision(payment_method: "ideal")

      expect(empty_decision).not_to be_eligible
      expect(empty_decision.fallback_reason).to eq(:no_purchases)
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

  describe ".direct_listed_line_items_eligible?" do
    def cad_line_item(product, **overrides)
      Checkout::BuyerCurrencyQuote::LineItem.new(
        permalink: product.unique_permalink,
        product:,
        tip_cents: 0,
        shipping_cents: 0,
        listed_currency_rate: "0.8",
        **overrides
      )
    end

    def eligible_for?(product, **overrides)
      described_class.direct_listed_line_items_eligible?(
        line_items: [cad_line_item(product, **overrides)],
        buyer_currency: Currency::CAD
      )
    end

    let(:cad_product) { create(:product, user: seller, price_currency_type: Currency::CAD, price_cents: 10_00) }

    before do
      Feature.activate_user(described_class::LISTED_CURRENCY_DIRECT_CHARGE_FEATURE_NAME, seller)
    end

    it "advertises the listed currency for a tipped cart the listed lane can charge" do
      merchant_account

      expect(eligible_for?(cad_product, tip_cents: 200)).to be(true)
    end

    it "refuses a seller whose charging account cannot create the intent" do
      # The seller's only account is a Gumroad-managed Stripe Custom account, outside the
      # destination-charge ramp. #decision refuses that at :unsupported_charge_model before it
      # reaches the listed lane, so the menu must not offer the currency either.
      create(:merchant_account, user: seller, currency: Currency::USD)

      expect(eligible_for?(cad_product)).to be(false)
    end

    # `later_charge_kind` is the caller's summary of the charge, not a fact about the product, so
    # it cannot be what keeps these shapes out. #decision refuses both from the product itself at
    # :unsupported_product_type, and a currency advertised here that prepare then refuses is a
    # total that changes under the buyer. The supported account is set up in each so the account
    # gate above is not what answers.
    it "refuses a free-trial membership reported with no later charge" do
      merchant_account
      Feature.activate_user(described_class::SUBSCRIPTION_FEATURE_NAME, seller)
      membership = create(:membership_product, :with_free_trial_enabled, user: seller, price_currency_type: Currency::CAD)

      expect(eligible_for?(membership)).to be(false)
    end

    it "refuses a membership reported with no later charge while the subscription ramp is off" do
      merchant_account
      membership = create(:membership_product, user: seller, price_currency_type: Currency::CAD)

      expect(eligible_for?(membership)).to be(false)
    end
  end

  describe ".buyer_presentment_display?" do
    it "treats a local currency other than USD as presentment" do
      expect(described_class.buyer_presentment_display?(display_mode: "buyer_local", buyer_currency_shown: "eur")).to be(true)
    end

    # A USD display is the converted price of a non-USD-priced product shown to a US buyer, and
    # that is the amount the charge already uses, so no quote is ever minted for it. Callers
    # disable wallet buttons for presentment carts, and doing that here would cost the buyer
    # Apple Pay and Google Pay for nothing.
    it "does not treat a USD local currency as presentment" do
      expect(described_class.buyer_presentment_display?(display_mode: "buyer_local", buyer_currency_shown: "usd")).to be(false)
    end

    it "reads string keys the same way as symbol keys" do
      expect(described_class.buyer_presentment_display?("display_mode" => "buyer_local", "buyer_currency_shown" => "usd")).to be(false)
      expect(described_class.buyer_presentment_display?("display_mode" => "buyer_local", "buyer_currency_shown" => "gbp")).to be(true)
    end

    it "is false for a default display and for a blank payload" do
      expect(described_class.buyer_presentment_display?(display_mode: "default", buyer_currency_shown: "eur")).to be(false)
      expect(described_class.buyer_presentment_display?(nil)).to be(false)
    end
  end
end
