# frozen_string_literal: true

describe Checkout::StripePaymentPresenter do
  def checkout_product_for(product, price: product.price_cents, recurrence: nil, pay_in_installments: false,
                           is_preorder: product.is_in_preorder_state, free_trial: product.free_trial_enabled,
                           native_type: product.native_type, buyer_currency_display: nil, ppp_details: nil)
    {
      product: {
        creator: { id: product.user.external_id },
        is_preorder:,
        free_trial: free_trial ? { duration: { unit: "day", amount: 1 } } : nil,
        native_type:,
        buyer_currency_display:,
        ppp_details:,
      },
      price:,
      recurrence:,
      pay_in_installments:,
    }
  end

  def flagged_seller_product(**overrides)
    seller = create(:user)
    product = create(:product, user: seller, price_cents: 1234)
    Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
    checkout_product_for(product, **overrides)
  end

  def confirm_flagged_seller_product(**overrides)
    seller = create(:user)
    product = create(:product, user: seller, price_cents: 1234)
    Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
    Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CLIENT_CONFIRM_FEATURE_NAME, seller)
    checkout_product_for(product, **overrides)
  end

  def card_element_fallback(reason, request_apple_pay_merchant_tokens: false)
    { integration: described_class::STRIPE_CARD_ELEMENT_INTEGRATION, fallback_reason: reason, disable_wallets: false, request_apple_pay_merchant_tokens:, elements_options: nil }
  end

  # The Element's Link toggle and the intent's method list derive from the same resolver output, so
  # they move together; Link is always launched, and the US-locked methods (cashapp/us_bank_account)
  # are passed explicitly by the region-gate specs.
  def payment_element_client_confirm_props(stripe_link_enabled: true, payment_method_types: %w[card link], stripe_connect_account_id: nil, request_apple_pay_merchant_tokens: false)
    {
      integration: described_class::STRIPE_PAYMENT_ELEMENT_CLIENT_CONFIRM_INTEGRATION,
      fallback_reason: nil,
      disable_wallets: false,
      request_apple_pay_merchant_tokens:,
      elements_options: {
        stripe_elements_mode: described_class::STRIPE_ELEMENTS_MODE_FOR_PAYMENT_INTENT,
        currency: "usd",
        payment_method_types:,
        stripe_link_enabled:,
        stripe_connect_account_id:,
      },
    }
  end

  def payment_element_props(stripe_elements_mode: described_class::STRIPE_ELEMENTS_MODE_FOR_PAYMENT_INTENT, stripe_link_enabled: true, request_apple_pay_merchant_tokens: false)
    {
      integration: described_class::STRIPE_PAYMENT_ELEMENT_INTEGRATION,
      fallback_reason: nil,
      disable_wallets: false,
      request_apple_pay_merchant_tokens:,
      elements_options: {
        stripe_elements_mode:,
        currency: "usd",
        payment_method_types: ["card"],
        payment_method_creation: "manual",
        stripe_link_enabled:,
      },
    }
  end

  def stripe_payment_props(cart: nil, add_products: [], clear_cart: false, saved_credit_card: nil, ip: nil)
    described_class.new(cart:, add_products:, clear_cart:, saved_credit_card:, ip:).props
  end

  def stub_geoip_country(ip, country_name)
    allow(GeoIp).to receive(:lookup).with(ip).and_return(double(country_name:))
  end

  it "selects Stripe Payment Element for a flagged single-seller charged checkout without a saved card" do
    seller = create(:user)
    product = create(:product, user: seller, price_cents: 1234)
    Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)

    expect(stripe_payment_props(add_products: [checkout_product_for(product)])).to eq(payment_element_props)
  end

  it "selects Stripe Payment Element for a flagged single-seller direct-charge checkout" do
    seller = create(:user, check_merchant_account_is_linked: true)
    product = create(:product, user: seller, price_cents: 1234)
    create(:merchant_account_stripe_connect, user: seller)
    Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)

    expect(stripe_payment_props(add_products: [checkout_product_for(product)])).to eq(payment_element_props)
  end

  it "selects Stripe Payment Element even when the buyer has a saved card" do
    seller = create(:user)
    product = create(:product, user: seller, price_cents: 1234)
    Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
    saved_credit_card = { type: "visa", number: "**** **** **** 4242", expiration_date: "12/30", requires_mandate: false }

    expect(stripe_payment_props(add_products: [checkout_product_for(product)], saved_credit_card:)).to eq(payment_element_props)
  end

  it "falls back to CardElement when the Stripe Payment Element seller flag is disabled" do
    product = create(:product, price_cents: 1234)

    expect(stripe_payment_props(add_products: [checkout_product_for(product)]))
      .to eq(card_element_fallback("stripe_payment_element_flag_disabled"))
  end

  it "falls back to CardElement when buyer-currency presentment is enabled for the checkout" do
    seller = create(:user, disable_buyer_local_currency: false)
    product = create(:product, user: seller, price_cents: 1234)
    allow(Stripe).to receive(:api_key).and_return("sk_test_currency")
    Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
    Feature.activate_user(:buyer_local_currency, seller)
    Feature.activate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)
    add_products = [
      checkout_product_for(
        product,
        buyer_currency_display: {
          display_mode: "buyer_local",
          buyer_currency_shown: Currency::CAD,
        }
      )
    ]

    expect(stripe_payment_props(add_products:)).to eq(
      integration: described_class::STRIPE_CARD_ELEMENT_INTEGRATION,
      fallback_reason: "buyer_currency_presentment_unsupported",
      disable_wallets: true,
      request_apple_pay_merchant_tokens: false,
      elements_options: nil,
    )
  ensure
    Feature.deactivate_user(:buyer_local_currency, seller) if seller
    Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller) if seller
  end

  it "keeps the existing Payment Element and wallet path in live mode" do
    seller = create(:user, disable_buyer_local_currency: false)
    product = create(:product, user: seller, price_cents: 1234)
    allow(Stripe).to receive(:api_key).and_return("sk_live_currency")
    Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
    Feature.activate_user(:buyer_local_currency, seller)
    Feature.activate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)
    add_products = [
      checkout_product_for(
        product,
        buyer_currency_display: {
          display_mode: "buyer_local",
          buyer_currency_shown: Currency::CAD,
        }
      )
    ]

    expect(stripe_payment_props(add_products:)).to eq(payment_element_props)
  ensure
    Feature.deactivate_user(:buyer_local_currency, seller) if seller
    Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller) if seller
  end

  it "selects Stripe Payment Element for a multi-seller cart when every seller is flagged" do
    cart = create(:cart, :guest)
    products = [
      create(:product, user: create(:user), price_cents: 100),
      create(:product, user: create(:user), price_cents: 200),
    ]
    products.each do |product|
      Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, product.user)
      create(:cart_product, cart:, product:)
    end

    expect(stripe_payment_props(cart:)).to eq(payment_element_props)
  end

  it "falls back to CardElement for a multi-seller cart when any seller is not flagged" do
    cart = create(:cart, :guest)
    products = [
      create(:product, user: create(:user), price_cents: 100),
      create(:product, user: create(:user), price_cents: 200),
    ]
    Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, products.first.user)
    products.each { |product| create(:cart_product, cart:, product:) }

    expect(stripe_payment_props(cart:)).to eq(card_element_fallback("stripe_payment_element_flag_disabled"))
  end

  it "falls back to CardElement for an empty checkout" do
    expect(stripe_payment_props).to eq(card_element_fallback("empty_cart"))
  end

  it "falls back to CardElement when a checkout product's seller cannot be resolved" do
    add_products = [{ product: { creator: { id: "nonexistent-seller" }, is_preorder: false, free_trial: nil, native_type: "digital" }, price: 1234, recurrence: nil, pay_in_installments: false }]

    expect(stripe_payment_props(add_products:)).to eq(card_element_fallback("unknown_seller"))
  end

  it "selects Stripe Payment Element for a recurring membership product" do
    expect(stripe_payment_props(add_products: [flagged_seller_product(recurrence: "monthly")]))
      .to eq(payment_element_props)
  end

  it "selects Stripe Payment Element for a commission product" do
    expect(stripe_payment_props(add_products: [flagged_seller_product(native_type: Link::NATIVE_TYPE_COMMISSION)]))
      .to eq(payment_element_props)
  end

  it "falls back to CardElement for an installment-plan product" do
    expect(stripe_payment_props(add_products: [flagged_seller_product(pay_in_installments: true)]))
      .to eq(card_element_fallback("setup_or_installment_flow"))
  end

  it "selects Stripe Payment Element SetupIntent mode for a preorder product" do
    expect(stripe_payment_props(add_products: [flagged_seller_product(is_preorder: true)]))
      .to eq(payment_element_props(stripe_elements_mode: described_class::STRIPE_ELEMENTS_MODE_FOR_SETUP_INTENT))
  end

  it "selects Stripe Payment Element SetupIntent mode for a free-trial product" do
    expect(stripe_payment_props(add_products: [flagged_seller_product(free_trial: true, recurrence: "monthly")]))
      .to eq(payment_element_props(stripe_elements_mode: described_class::STRIPE_ELEMENTS_MODE_FOR_SETUP_INTENT))
  end

  it "falls back to CardElement when future-charge products are mixed with charged products" do
    seller = create(:user)
    Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
    future_charge_product = create(:product, user: seller, price_cents: 1234)
    charged_product = create(:product, user: seller, price_cents: 5678)

    expect(stripe_payment_props(add_products: [
                                  checkout_product_for(future_charge_product, is_preorder: true),
                                  checkout_product_for(charged_product),
                                ]))
      .to eq(card_element_fallback("setup_or_installment_flow"))
  end

  it "selects Stripe Payment Element SetupIntent mode for a recurring free-trial product" do
    expect(stripe_payment_props(add_products: [flagged_seller_product(recurrence: "monthly", free_trial: true)]))
      .to eq(payment_element_props(stripe_elements_mode: described_class::STRIPE_ELEMENTS_MODE_FOR_SETUP_INTENT))
  end

  it "selects Stripe Payment Element SetupIntent mode for mixed future-charge products" do
    seller = create(:user)
    Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
    preorder_product = create(:product, user: seller, price_cents: 1234)
    free_trial_product = create(:product, user: seller, price_cents: 5678)

    expect(stripe_payment_props(add_products: [
                                  checkout_product_for(preorder_product, is_preorder: true),
                                  checkout_product_for(free_trial_product, free_trial: true, recurrence: "monthly"),
                                ]))
      .to eq(payment_element_props(stripe_elements_mode: described_class::STRIPE_ELEMENTS_MODE_FOR_SETUP_INTENT))
  end

  it "falls back to CardElement when the checkout total is not positive" do
    expect(stripe_payment_props(add_products: [flagged_seller_product(price: 0)]))
      .to eq(card_element_fallback("not_charged"))
  end

  it "falls back to CardElement for a future-charge product with no future charge amount" do
    expect(stripe_payment_props(add_products: [flagged_seller_product(is_preorder: true, price: 0)]))
      .to eq(card_element_fallback("setup_or_installment_flow"))
  end

  it "falls back to CardElement when the charged checkout total is below the Payment Element minimum" do
    expect(
      stripe_payment_props(
        add_products: [flagged_seller_product(price: described_class::STRIPE_PAYMENT_ELEMENT_MINIMUM_USD_CHARGE_CENTS - 1)]
      )
    )
      .to eq(card_element_fallback("stripe_payment_element_amount_below_minimum"))
  end

  it "selects Stripe Payment Element when the charged checkout total is below Gumroad's USD minimum but chargeable by Stripe" do
    gumroad_minimum_price_cents = CURRENCY_CHOICES[Currency::USD][:min_price]

    expect(
      stripe_payment_props(
        add_products: [flagged_seller_product(price: gumroad_minimum_price_cents - 1)]
      )
    ).to eq(payment_element_props)
  end

  it "selects Stripe Payment Element for mixed free and paid products when the charged total meets the minimum" do
    seller = create(:user)
    minimum_charge_cents = described_class::STRIPE_PAYMENT_ELEMENT_MINIMUM_USD_CHARGE_CENTS
    free_product = create(:product, user: seller, price_cents: 0)
    paid_product = create(:product, user: seller, price_cents: CURRENCY_CHOICES[Currency::USD][:min_price])
    Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)

    expect(
      stripe_payment_props(
        add_products: [
          checkout_product_for(free_product, price: 0),
          checkout_product_for(paid_product, price: minimum_charge_cents),
        ]
      )
    ).to eq(payment_element_props)
  end

  it "falls back to CardElement for mixed free and paid products when the charged total is below the minimum" do
    seller = create(:user)
    minimum_price_cents = described_class::STRIPE_PAYMENT_ELEMENT_MINIMUM_USD_CHARGE_CENTS
    free_product = create(:product, user: seller, price_cents: 0)
    paid_product = create(:product, user: seller, price_cents: CURRENCY_CHOICES[Currency::USD][:min_price])
    Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)

    expect(
      stripe_payment_props(
        add_products: [
          checkout_product_for(free_product, price: 0),
          checkout_product_for(paid_product, price: minimum_price_cents - 1),
        ]
      )
    ).to eq(card_element_fallback("stripe_payment_element_amount_below_minimum"))
  end

  it "ignores cart products when clear_cart is set" do
    cart = create(:cart, :guest)
    create(:cart_product, cart:, product: create(:product, user: create(:user)))

    expect(stripe_payment_props(cart:, add_products: [flagged_seller_product], clear_cart: true)).to eq(payment_element_props)
  end

  it "always enables Link in the Payment Element (no per-seller flag)" do
    seller = create(:user)
    product = create(:product, user: seller, price_cents: 1234)
    Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)

    expect(stripe_payment_props(add_products: [checkout_product_for(product)])).to eq(payment_element_props(stripe_link_enabled: true))
  end

  it "disables Link on a PPP-verified Payment Element checkout — its funding country is not verifiable pre-charge" do
    stub_geoip_country("104.28.0.1", "United States")
    ppp_details = { country: "Brazil", factor: 0.5, minimum_price: 99 }

    props = stripe_payment_props(add_products: [flagged_seller_product(ppp_details:)], ip: "104.28.0.1")

    expect(props).to eq(payment_element_props(stripe_link_enabled: false))
  end

  it "keeps Link on a PPP Payment Element checkout when the seller disabled PPP payment verification" do
    stub_geoip_country("104.28.0.1", "United States")
    ppp_details = { country: "Brazil", factor: 0.5, minimum_price: 99 }
    item = flagged_seller_product(ppp_details:)
    seller = User.find_by(external_id: item[:product][:creator][:id])
    seller.update!(purchasing_power_parity_payment_verification_disabled: true)

    props = stripe_payment_props(add_products: [item], ip: "104.28.0.1")

    expect(props).to eq(payment_element_props(stripe_link_enabled: true))
  end

  it "gates Link item-scoped: another seller disabling PPP verification does not re-enable Link for a still-verified PPP item" do
    stub_geoip_country("104.28.0.1", "United States")
    ppp_details = { country: "Brazil", factor: 0.5, minimum_price: 99 }
    verified_ppp_item = flagged_seller_product(ppp_details:)
    unverified_seller_item = flagged_seller_product
    unverified_seller = User.find_by(external_id: unverified_seller_item[:product][:creator][:id])
    unverified_seller.update!(purchasing_power_parity_payment_verification_disabled: true)

    props = stripe_payment_props(add_products: [verified_ppp_item, unverified_seller_item], ip: "104.28.0.1")

    expect(props).to eq(payment_element_props(stripe_link_enabled: false))
  end

  it "keeps Link on a multi-seller cart when the only PPP item's own seller disabled verification" do
    stub_geoip_country("104.28.0.1", "United States")
    ppp_details = { country: "Brazil", factor: 0.5, minimum_price: 99 }
    ppp_item = flagged_seller_product(ppp_details:)
    ppp_seller = User.find_by(external_id: ppp_item[:product][:creator][:id])
    ppp_seller.update!(purchasing_power_parity_payment_verification_disabled: true)
    other_item = flagged_seller_product

    props = stripe_payment_props(add_products: [ppp_item, other_item], ip: "104.28.0.1")

    expect(props).to eq(payment_element_props(stripe_link_enabled: true))
  end

  describe "Payment Element confirm integration" do
    it "selects the confirm integration for a single-seller one-time card cart with both flags" do
      expect(stripe_payment_props(add_products: [confirm_flagged_seller_product]))
        .to eq(payment_element_client_confirm_props)
    end

    it "launches Cash App Pay and ACH Direct Debit alongside card for a US buyer" do
      stub_geoip_country("104.28.0.1", "United States")

      expect(stripe_payment_props(add_products: [confirm_flagged_seller_product], ip: "104.28.0.1"))
        .to eq(payment_element_client_confirm_props(payment_method_types: %w[card link cashapp us_bank_account]))
    end

    it "offers card and Link only for a non-US buyer (Cash App/ACH are US-locked)" do
      stub_geoip_country("2.2.2.2", "United Kingdom")

      expect(stripe_payment_props(add_products: [confirm_flagged_seller_product], ip: "2.2.2.2"))
        .to eq(payment_element_client_confirm_props(payment_method_types: %w[card link]))
    end

    it "offers card and Link only when the buyer's country cannot be resolved" do
      allow(GeoIp).to receive(:lookup).and_return(nil)

      expect(stripe_payment_props(add_products: [confirm_flagged_seller_product], ip: "0.0.0.0"))
        .to eq(payment_element_client_confirm_props(payment_method_types: %w[card link]))
    end

    describe "PPP method matrix (U13)" do
      let(:ppp_details) { { country: "Brazil", factor: 0.5, minimum_price: 99 } }

      it "keeps card and the US-locked methods on a PPP checkout for a US buyer" do
        stub_geoip_country("104.28.0.1", "United States")

        expect(stripe_payment_props(add_products: [confirm_flagged_seller_product(ppp_details:)], ip: "104.28.0.1"))
          .to eq(payment_element_client_confirm_props(payment_method_types: %w[card cashapp us_bank_account], stripe_link_enabled: false))
      end

      it "gates Link out on a PPP checkout — its funding country is not verifiable pre-charge" do
        stub_geoip_country("104.28.0.1", "United States")

        props = stripe_payment_props(add_products: [confirm_flagged_seller_product(ppp_details:)], ip: "104.28.0.1")

        expect(props[:elements_options][:payment_method_types]).to eq(%w[card cashapp us_bank_account])
        expect(props[:elements_options][:stripe_link_enabled]).to eq(false)
      end

      it "does not gate methods when the seller disabled PPP payment verification" do
        stub_geoip_country("104.28.0.1", "United States")
        item = confirm_flagged_seller_product(ppp_details:)
        seller = User.find_by(external_id: item[:product][:creator][:id])
        seller.update!(purchasing_power_parity_payment_verification_disabled: true)

        props = stripe_payment_props(add_products: [item], ip: "104.28.0.1")

        expect(props[:elements_options][:payment_method_types]).to eq(%w[card link cashapp us_bank_account])
      end

      it "leaves a non-PPP checkout's method set untouched" do
        stub_geoip_country("104.28.0.1", "United States")

        expect(stripe_payment_props(add_products: [confirm_flagged_seller_product], ip: "104.28.0.1"))
          .to eq(payment_element_client_confirm_props(payment_method_types: %w[card link cashapp us_bank_account]))
      end
    end

    it "keeps server-confirm Payment Element when only the base flag is enabled" do
      expect(stripe_payment_props(add_products: [flagged_seller_product])).to eq(payment_element_props)
    end

    it "falls back to CardElement when only the confirm flag is enabled but the base flag is not" do
      seller = create(:user)
      product = create(:product, user: seller, price_cents: 1234)
      Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CLIENT_CONFIRM_FEATURE_NAME, seller)

      expect(stripe_payment_props(add_products: [checkout_product_for(product)]))
        .to eq(card_element_fallback("stripe_payment_element_flag_disabled"))
    end

    it "keeps server-confirm Payment Element for a multi-seller cart even when every seller has both flags" do
      cart = create(:cart, :guest)
      [100, 200].each do |price_cents|
        product = create(:product, user: create(:user), price_cents:)
        Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, product.user)
        Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CLIENT_CONFIRM_FEATURE_NAME, product.user)
        create(:cart_product, cart:, product:)
      end

      expect(stripe_payment_props(cart:)).to eq(payment_element_props)
    end

    it "keeps server-confirm Payment Element for a recurring membership because client-confirm mode is one-time only" do
      expect(stripe_payment_props(add_products: [confirm_flagged_seller_product(recurrence: "monthly")]))
        .to eq(payment_element_props)
    end

    it "keeps server-confirm Payment Element for a commission product even with both flags" do
      expect(stripe_payment_props(add_products: [confirm_flagged_seller_product(native_type: Link::NATIVE_TYPE_COMMISSION)]))
        .to eq(payment_element_props)
    end

    it "keeps server-confirm SetupIntent mode for a preorder even with both flags" do
      expect(stripe_payment_props(add_products: [confirm_flagged_seller_product(is_preorder: true)]))
        .to eq(payment_element_props(stripe_elements_mode: described_class::STRIPE_ELEMENTS_MODE_FOR_SETUP_INTENT))
    end

    it "selects the confirm integration for a direct-charge seller with Elements scoped to the connected account" do
      seller = create(:user, check_merchant_account_is_linked: true)
      product = create(:product, user: seller, price_cents: 1234)
      connect_account = create(:merchant_account_stripe_connect, user: seller)
      Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
      Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CLIENT_CONFIRM_FEATURE_NAME, seller)

      expect(stripe_payment_props(add_products: [checkout_product_for(product)]))
        .to eq(payment_element_client_confirm_props(stripe_connect_account_id: connect_account.charge_processor_merchant_id))
    end

    it "always enables Link in client-confirm mode (no per-seller flag)" do
      seller = create(:user)
      product = create(:product, user: seller, price_cents: 1234)
      Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
      Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CLIENT_CONFIRM_FEATURE_NAME, seller)

      expect(stripe_payment_props(add_products: [checkout_product_for(product)]))
        .to eq(payment_element_client_confirm_props(stripe_link_enabled: true))
    end
  end

  describe "Apple Pay merchant token flag" do
    it "requests merchant tokens on the Payment Element integration when the seller is flagged" do
      seller = create(:user)
      product = create(:product, user: seller, price_cents: 1234)
      Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
      Feature.activate_user(described_class::APPLE_PAY_MERCHANT_TOKENS_FEATURE_NAME, seller)

      expect(stripe_payment_props(add_products: [checkout_product_for(product)]))
        .to eq(payment_element_props(request_apple_pay_merchant_tokens: true))
    end

    it "requests merchant tokens on the CardElement fallback when the seller is flagged" do
      # The wallet button renders on CardElement checkouts too (installment plans and other
      # Payment Element fallbacks), so the flag must reach the frontend on every integration.
      seller = create(:user)
      product = create(:product, user: seller, price_cents: 1234)
      Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
      Feature.activate_user(described_class::APPLE_PAY_MERCHANT_TOKENS_FEATURE_NAME, seller)

      expect(stripe_payment_props(add_products: [checkout_product_for(product, pay_in_installments: true)]))
        .to eq(card_element_fallback("setup_or_installment_flow", request_apple_pay_merchant_tokens: true))
    end

    it "requests merchant tokens on the client-confirm integration when the seller is flagged" do
      seller = create(:user)
      product = create(:product, user: seller, price_cents: 1234)
      Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
      Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CLIENT_CONFIRM_FEATURE_NAME, seller)
      Feature.activate_user(described_class::APPLE_PAY_MERCHANT_TOKENS_FEATURE_NAME, seller)

      expect(stripe_payment_props(add_products: [checkout_product_for(product)]))
        .to eq(payment_element_client_confirm_props(request_apple_pay_merchant_tokens: true))
    end

    it "does not request merchant tokens when the seller is not flagged" do
      expect(stripe_payment_props(add_products: [flagged_seller_product]))
        .to eq(payment_element_props(request_apple_pay_merchant_tokens: false))
    end

    it "does not request merchant tokens when any seller in the cart is not flagged" do
      flagged_seller = create(:user)
      flagged = create(:product, user: flagged_seller, price_cents: 1234)
      Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, flagged_seller)
      Feature.activate_user(described_class::APPLE_PAY_MERCHANT_TOKENS_FEATURE_NAME, flagged_seller)
      unflagged_seller = create(:user)
      unflagged = create(:product, user: unflagged_seller, price_cents: 1234)
      Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, unflagged_seller)

      expect(stripe_payment_props(add_products: [checkout_product_for(flagged), checkout_product_for(unflagged)]))
        .to eq(payment_element_props(request_apple_pay_merchant_tokens: false))
    end

    it "does not request merchant tokens for an empty cart" do
      expect(stripe_payment_props)
        .to eq(card_element_fallback("empty_cart", request_apple_pay_merchant_tokens: false))
    end
  end
end
