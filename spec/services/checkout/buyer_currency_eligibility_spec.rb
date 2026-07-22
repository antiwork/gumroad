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

  it "falls back without an FX-quote round trip when a settlement-currency mismatch was recorded for the account" do
    # The stored currency still says usd for accounts with Stripe multi-currency
    # settlement — the recorded marker from a previously rejected FX quote is what tells
    # checkout the quote call is doomed (issue #6011).
    merchant_account.record_settlement_currency_mismatch!

    expect(decision).not_to be_eligible
    expect(decision.fallback_reason).to eq(:unsupported_settlement_currency)
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

  it "falls back for free-trial products" do
    free_trial_product = create(:membership_product, :with_free_trial_enabled, user: seller, price_currency_type: Currency::USD)
    purchase.update!(link: free_trial_product)

    expect(decision).not_to be_eligible
    expect(decision.fallback_reason).to eq(:unsupported_product_type)
  end

  it "falls back for products offering an installment plan" do
    installment_product = create(:product, user: seller, price_cents: 9_00, price_currency_type: Currency::USD)
    create(:product_installment_plan, link: installment_product, number_of_installments: 3)
    purchase.update!(link: installment_product.reload)

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

  it "falls back for orders spanning multiple sellers" do
    # ChargeService creates one charge per seller, so this service only ever sees one
    # seller's purchases — the multi-seller signal lives on the order.
    other_seller = create(:user)
    other_seller_purchase = create(:purchase,
                                   link: create(:product, user: other_seller),
                                   seller: other_seller,
                                   purchase_state: "in_progress")
    order.purchases << purchase
    order.purchases << other_seller_purchase

    expect(decision).not_to be_eligible
    expect(decision.fallback_reason).to eq(:multi_seller_checkout)
  end

  it "falls back when any purchase on the charge fails a product gate" do
    purchases << create(:purchase,
                        link: create(:product, user: seller, price_currency_type: Currency::EUR),
                        seller:,
                        merchant_account:,
                        purchase_state: "in_progress",
                        ip_address: "203.0.113.1")

    expect(decision).not_to be_eligible
    expect(decision.fallback_reason).to eq(:unsupported_product_currency)
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
