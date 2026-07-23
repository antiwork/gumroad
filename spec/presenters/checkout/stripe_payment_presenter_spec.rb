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
        # The product's own pricing currency, mirroring CheckoutPresenter#product_common,
        # which sets currency_code on every real add_products entry.
        currency_code: product.price_currency_type.to_s.downcase,
        installment_plan: product.installment_plan.present? ? {
          number_of_installments: product.installment_plan.number_of_installments,
          recurrence: product.installment_plan.recurrence,
        } : nil,
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
    { integration: described_class::STRIPE_CARD_ELEMENT_INTEGRATION, fallback_reason: reason, disable_wallets: false, request_apple_pay_merchant_tokens:, payment_element_wallets: false, elements_options: nil }
  end

  # The Element's Link toggle and the intent's method list derive from the same resolver output, so
  # they move together; Link is always launched, and the US-locked methods (cashapp/us_bank_account)
  # are passed explicitly by the region-gate specs.
  def payment_element_client_confirm_props(stripe_link_enabled: true, payment_method_types: %w[card link], stripe_connect_account_id: nil, currency: "usd", presentment_amount_cents: nil, disable_wallets: false, request_apple_pay_merchant_tokens: false, payment_element_wallets: false)
    {
      integration: described_class::STRIPE_PAYMENT_ELEMENT_CLIENT_CONFIRM_INTEGRATION,
      fallback_reason: nil,
      disable_wallets:,
      request_apple_pay_merchant_tokens:,
      payment_element_wallets:,
      elements_options: {
        stripe_elements_mode: described_class::STRIPE_ELEMENTS_MODE_FOR_PAYMENT_INTENT,
        currency:,
        presentment_amount_cents:,
        payment_method_types:,
        stripe_link_enabled:,
        stripe_connect_account_id:,
      },
    }
  end

  def payment_element_props(stripe_elements_mode: described_class::STRIPE_ELEMENTS_MODE_FOR_PAYMENT_INTENT, stripe_link_enabled: true, request_apple_pay_merchant_tokens: false, buyer_currency_presentment: false, disable_wallets: false, payment_element_wallets: false)
    {
      integration: described_class::STRIPE_PAYMENT_ELEMENT_INTEGRATION,
      fallback_reason: nil,
      disable_wallets:,
      request_apple_pay_merchant_tokens:,
      payment_element_wallets:,
      elements_options: {
        stripe_elements_mode:,
        currency: "usd",
        buyer_currency_presentment:,
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

  it "selects the buyer-currency presentment Payment Element for a single USD one-time item with presentment enabled" do
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
      payment_element_props(buyer_currency_presentment: true, disable_wallets: true)
    )
  ensure
    Feature.deactivate_user(:buyer_local_currency, seller) if seller
    Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller) if seller
  end

  it "selects the buyer-currency presentment Payment Element for a multi-item single-seller cart of USD one-time items" do
    seller = create(:user, disable_buyer_local_currency: false)
    product = create(:product, user: seller, price_cents: 1234)
    other_product = create(:product, user: seller, price_cents: 500)
    allow(Stripe).to receive(:api_key).and_return("sk_test_currency")
    Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
    Feature.activate_user(:buyer_local_currency, seller)
    Feature.activate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)
    buyer_currency_display = {
      display_mode: "buyer_local",
      buyer_currency_shown: Currency::CAD,
    }
    # One seller means one charge (one PaymentIntent), so the quote's locked cart total
    # can price the intent directly — the shape the presentment charge path supports.
    add_products = [
      checkout_product_for(product, buyer_currency_display:),
      checkout_product_for(other_product, buyer_currency_display:),
    ]

    expect(stripe_payment_props(add_products:)).to eq(
      payment_element_props(buyer_currency_presentment: true, disable_wallets: true)
    )
  ensure
    Feature.deactivate_user(:buyer_local_currency, seller) if seller
    Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller) if seller
  end

  it "falls back to CardElement for a presentment-candidate cart spanning multiple sellers" do
    sellers = Array.new(2) { create(:user, disable_buyer_local_currency: false) }
    allow(Stripe).to receive(:api_key).and_return("sk_test_currency")
    buyer_currency_display = {
      display_mode: "buyer_local",
      buyer_currency_shown: Currency::CAD,
    }
    # Two sellers means two charges (two PaymentIntents), but the quote locks a single
    # cart total for a single intent — the multi-seller boundary the charge path does
    # not support — so the cart keeps riding CardElement and charges canonical USD.
    add_products = sellers.map do |seller|
      Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
      Feature.activate_user(:buyer_local_currency, seller)
      Feature.activate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)
      checkout_product_for(create(:product, user: seller, price_cents: 1234), buyer_currency_display:)
    end

    expect(stripe_payment_props(add_products:)).to eq(
      integration: described_class::STRIPE_CARD_ELEMENT_INTEGRATION,
      fallback_reason: "buyer_currency_presentment_unsupported",
      disable_wallets: true,
      request_apple_pay_merchant_tokens: false,
      payment_element_wallets: false,
      elements_options: nil,
    )
  ensure
    (sellers || []).each do |seller|
      Feature.deactivate_user(:buyer_local_currency, seller)
      Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)
    end
  end

  it "falls back to CardElement when any item in a multi-item candidate cart fails a presentment gate" do
    seller = create(:user, disable_buyer_local_currency: false)
    product = create(:product, user: seller, price_cents: 1234)
    eur_product = create(:product, user: seller, price_currency_type: "eur", price_cents: 500)
    allow(Stripe).to receive(:api_key).and_return("sk_test_currency")
    Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
    Feature.activate_user(:buyer_local_currency, seller)
    Feature.activate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)
    buyer_currency_display = {
      display_mode: "buyer_local",
      buyer_currency_shown: Currency::CAD,
    }
    # The quote locks the whole cart total, so a single non-USD item invalidates the
    # whole cart's presentment — everything falls back to canonical USD on CardElement.
    add_products = [
      checkout_product_for(product, buyer_currency_display:),
      checkout_product_for(eur_product, buyer_currency_display:),
    ]

    expect(stripe_payment_props(add_products:)).to eq(
      integration: described_class::STRIPE_CARD_ELEMENT_INTEGRATION,
      fallback_reason: "buyer_currency_presentment_unsupported",
      disable_wallets: true,
      request_apple_pay_merchant_tokens: false,
      payment_element_wallets: false,
      elements_options: nil,
    )
  ensure
    Feature.deactivate_user(:buyer_local_currency, seller) if seller
    Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller) if seller
  end

  it "falls back to CardElement when a one-time purchase offers an installment plan" do
    seller = create(:user, disable_buyer_local_currency: false)
    product = create(:product, user: seller, price_cents: 1234)
    create(:product_installment_plan, link: product)
    allow(Stripe).to receive(:api_key).and_return("sk_test_currency")
    Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
    Feature.activate_user(:buyer_local_currency, seller)
    Feature.activate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)
    add_products = [
      checkout_product_for(
        product,
        pay_in_installments: false,
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
      payment_element_wallets: false,
      elements_options: nil,
    )
  ensure
    Feature.deactivate_user(:buyer_local_currency, seller) if seller
    Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller) if seller
  end

  it "falls back to CardElement when the presentment candidate item is recurring" do
    seller = create(:user, disable_buyer_local_currency: false)
    product = create(:membership_product, user: seller, price_cents: 1234)
    allow(Stripe).to receive(:api_key).and_return("sk_test_currency")
    Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
    Feature.activate_user(:buyer_local_currency, seller)
    Feature.activate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)
    add_products = [
      checkout_product_for(
        product,
        # Membership products keep their price on tiers, so the checkout item's price must be
        # passed explicitly or the cart totals zero and trips the earlier not_charged fallback
        # before reaching the presentment gate this example is about.
        price: 1234,
        recurrence: "monthly",
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
      payment_element_wallets: false,
      elements_options: nil,
    )
  ensure
    Feature.deactivate_user(:buyer_local_currency, seller) if seller
    Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller) if seller
  end

  it "selects the buyer-currency presentment Payment Element in live mode now that the gate is lifted" do
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

    expect(stripe_payment_props(add_products:)).to eq(
      payment_element_props(buyer_currency_presentment: true, disable_wallets: true)
    )
  ensure
    Feature.deactivate_user(:buyer_local_currency, seller) if seller
    Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller) if seller
  end

  it "falls back to CardElement for a flag-on seller's unsupported presentment shape in live mode" do
    # Lifting the test-mode gate makes every buyer-local-display cart from a double-flagged
    # seller a presentment candidate in live, not just the supported card shape. Unsupported
    # shapes (here: a recurring membership) get the safety posture — CardElement with wallets
    # disabled — instead of the full Payment Element, because a wallet or multi-method charge
    # would collect canonical USD while the cart displays buyer-currency totals. This example
    # pins that live-mode downgrade so the flag ramp is done knowing a seller's whole catalog
    # changes checkout surface, not only their USD one-time products.
    seller = create(:user, disable_buyer_local_currency: false)
    product = create(:membership_product, user: seller, price_cents: 1234)
    allow(Stripe).to receive(:api_key).and_return("sk_live_currency")
    Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
    Feature.activate_user(:buyer_local_currency, seller)
    Feature.activate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)
    add_products = [
      checkout_product_for(
        product,
        # Membership products keep their price on tiers, so the checkout item's price must be
        # passed explicitly or the cart totals zero and trips the earlier not_charged fallback
        # before reaching the presentment gate this example is about.
        price: 1234,
        recurrence: "monthly",
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
      # CardElement fallbacks never mount a Payment Element, so the wallets-in-the-element
      # rollout flag can't apply — this branch's presenter reports the surface as off.
      payment_element_wallets: false,
      elements_options: nil,
    )
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

    it "launches Cash App Pay alongside card for a US buyer — ACH Direct Debit stays withdrawn platform-wide" do
      stub_geoip_country("104.28.0.1", "United States")

      expect(stripe_payment_props(add_products: [confirm_flagged_seller_product], ip: "104.28.0.1"))
        .to eq(payment_element_client_confirm_props(payment_method_types: %w[card link cashapp]))
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
          .to eq(payment_element_client_confirm_props(payment_method_types: %w[card cashapp], stripe_link_enabled: false))
      end

      it "gates Link out on a PPP checkout — its funding country is not verifiable pre-charge" do
        stub_geoip_country("104.28.0.1", "United States")

        props = stripe_payment_props(add_products: [confirm_flagged_seller_product(ppp_details:)], ip: "104.28.0.1")

        expect(props[:elements_options][:payment_method_types]).to eq(%w[card cashapp])
        expect(props[:elements_options][:stripe_link_enabled]).to eq(false)
      end

      it "does not gate methods when the seller disabled PPP payment verification" do
        stub_geoip_country("104.28.0.1", "United States")
        item = confirm_flagged_seller_product(ppp_details:)
        seller = User.find_by(external_id: item[:product][:creator][:id])
        seller.update!(purchasing_power_parity_payment_verification_disabled: true)

        props = stripe_payment_props(add_products: [item], ip: "104.28.0.1")

        expect(props[:elements_options][:payment_method_types]).to eq(%w[card link cashapp])
      end

      it "leaves a non-PPP checkout's method set untouched" do
        stub_geoip_country("104.28.0.1", "United States")

        expect(stripe_payment_props(add_products: [confirm_flagged_seller_product], ip: "104.28.0.1"))
          .to eq(payment_element_client_confirm_props(payment_method_types: %w[card link cashapp]))
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
      # A capability snapshot must exist for the account to offer anything beyond card
      # (an uncached connect account resolves card-only while the refresh worker runs).
      connect_account.update!(stripe_capabilities_snapshot: {
                                "capabilities" => { "link_payments" => "active" },
                                "refreshed_at" => Time.current.iso8601,
                              })
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

  describe "method-forced test-mode QA surface (iDEAL/Bancontact)" do
    def buyer_currency_seller_with_product(price_currency_type: "eur", price_cents: 1500)
      seller = create(:user, disable_buyer_local_currency: false)
      product = create(:product, user: seller, price_currency_type:, price_cents:)
      Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
      Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CLIENT_CONFIRM_FEATURE_NAME, seller)
      [seller, product]
    end

    def activate_buyer_currency_flags(seller)
      Feature.activate_user(:buyer_local_currency, seller)
      Feature.activate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)
    end

    def deactivate_buyer_currency_flags(seller)
      Feature.deactivate_user(:buyer_local_currency, seller)
      Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)
    end

    it "mounts the Payment Element in EUR with the listed amount and the EUR method tabs for an EUR-priced product in test mode with the flags on" do
      seller, product = buyer_currency_seller_with_product(price_cents: 1500)
      activate_buyer_currency_flags(seller)
      allow(Stripe).to receive(:api_key).and_return("sk_test_currency")

      expect(stripe_payment_props(add_products: [checkout_product_for(product)])).to eq(
        payment_element_client_confirm_props(
          currency: "eur",
          presentment_amount_cents: 1500,
          payment_method_types: %w[card link ideal bancontact],
          disable_wallets: true,
        )
      )
    ensure
      deactivate_buyer_currency_flags(seller) if seller
    end

    it "does not fall back to CardElement for a non-EU tester (buyer-local display) — the EUR element mounts with wallets disabled" do
      seller, product = buyer_currency_seller_with_product(price_cents: 1500)
      activate_buyer_currency_flags(seller)
      allow(Stripe).to receive(:api_key).and_return("sk_test_currency")
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
        payment_element_client_confirm_props(
          currency: "eur",
          presentment_amount_cents: 1500,
          payment_method_types: %w[card link ideal bancontact],
          disable_wallets: true,
        )
      )
    ensure
      deactivate_buyer_currency_flags(seller) if seller
    end

    it "keeps today's USD element behavior for the same EUR-priced cart in live mode when no local method is launched" do
      seller, product = buyer_currency_seller_with_product(price_cents: 1500)
      activate_buyer_currency_flags(seller)
      allow(Stripe).to receive(:api_key).and_return("sk_live_currency")

      expect(stripe_payment_props(add_products: [checkout_product_for(product)]))
        .to eq(payment_element_client_confirm_props)
    ensure
      deactivate_buyer_currency_flags(seller) if seller
    end

    it "mounts the EUR element with only the launched local method in live mode when its launch flag is on" do
      seller, product = buyer_currency_seller_with_product(price_cents: 1500)
      activate_buyer_currency_flags(seller)
      Feature.activate_user(:checkout_local_method_ideal, seller)
      allow(Stripe).to receive(:api_key).and_return("sk_live_currency")

      expect(stripe_payment_props(add_products: [checkout_product_for(product)])).to eq(
        payment_element_client_confirm_props(
          currency: "eur",
          presentment_amount_cents: 1500,
          payment_method_types: %w[card link ideal],
          disable_wallets: true,
        )
      )
    ensure
      if seller
        Feature.deactivate_user(:checkout_local_method_ideal, seller)
        deactivate_buyer_currency_flags(seller)
      end
    end

    it "mounts the INR element with UPI for an Indian buyer when UPI's launch flag is on" do
      seller, product = buyer_currency_seller_with_product(price_currency_type: "inr", price_cents: 7300)
      activate_buyer_currency_flags(seller)
      Feature.activate_user(:checkout_local_method_upi, seller)
      allow(Stripe).to receive(:api_key).and_return("sk_live_currency")
      stub_geoip_country("203.0.113.10", "India")

      expect(stripe_payment_props(add_products: [checkout_product_for(product)], ip: "203.0.113.10")).to eq(
        payment_element_client_confirm_props(
          currency: "inr",
          presentment_amount_cents: 7300,
          payment_method_types: %w[card link upi],
          disable_wallets: true,
        )
      )
    ensure
      if seller
        Feature.deactivate_user(:checkout_local_method_upi, seller)
        deactivate_buyer_currency_flags(seller)
      end
    end

    it "keeps the canonical USD element for a non-India buyer of an INR product even when UPI's launch flag is on" do
      seller, product = buyer_currency_seller_with_product(price_currency_type: "inr", price_cents: 7300)
      activate_buyer_currency_flags(seller)
      Feature.activate_user(:checkout_local_method_upi, seller)
      allow(Stripe).to receive(:api_key).and_return("sk_live_currency")
      stub_geoip_country("203.0.113.11", "United States")

      expect(stripe_payment_props(add_products: [checkout_product_for(product)], ip: "203.0.113.11"))
        .to eq(payment_element_client_confirm_props(payment_method_types: %w[card link cashapp]))
    ensure
      if seller
        Feature.deactivate_user(:checkout_local_method_upi, seller)
        deactivate_buyer_currency_flags(seller)
      end
    end

    it "keeps the canonical USD element for a direct-charge seller without an iDEAL capability snapshot" do
      seller = create(:user, check_merchant_account_is_linked: true, disable_buyer_local_currency: false)
      product = create(:product, user: seller, price_currency_type: Currency::EUR, price_cents: 1500)
      connect_account = create(:merchant_account_stripe_connect, user: seller)
      Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
      Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CLIENT_CONFIRM_FEATURE_NAME, seller)
      activate_buyer_currency_flags(seller)
      Feature.activate_user(:checkout_local_method_ideal, seller)
      allow(Stripe).to receive(:api_key).and_return("sk_live_currency")
      allow(RefreshMerchantAccountPaymentMethodAvailabilityWorker).to receive(:perform_async)

      expect(stripe_payment_props(add_products: [checkout_product_for(product)])).to eq(
        payment_element_client_confirm_props(
          payment_method_types: ["card"],
          stripe_link_enabled: false,
          stripe_connect_account_id: connect_account.charge_processor_merchant_id,
        )
      )
    ensure
      if seller
        Feature.deactivate_user(:checkout_local_method_ideal, seller)
        deactivate_buyer_currency_flags(seller)
      end
    end

    it "selects the buyer-currency presentment Payment Element for a non-US buyer of a USD-priced product with the flags on" do
      seller, product = buyer_currency_seller_with_product(price_currency_type: "usd", price_cents: 1500)
      activate_buyer_currency_flags(seller)
      allow(Stripe).to receive(:api_key).and_return("sk_test_currency")
      add_products = [
        checkout_product_for(
          product,
          buyer_currency_display: {
            display_mode: "buyer_local",
            buyer_currency_shown: Currency::CAD,
          }
        )
      ]

      # This cart used to dead-end on CardElement ("buyer_currency_presentment_unsupported"):
      # the method-forced QA surface only covers products priced in a forced currency, and the
      # canonical USD element couldn't present buyer currency. The presentment element shape
      # now carries it — a server-confirm Payment Element the browser mounts in the buyer's
      # FX-quote currency.
      expect(stripe_payment_props(add_products:)).to eq(
        payment_element_props(buyer_currency_presentment: true, disable_wallets: true)
      )
    ensure
      deactivate_buyer_currency_flags(seller) if seller
    end

    it "drops the US-locked methods (Cash App Pay, ACH) from the forced-currency element for a US buyer" do
      seller, product = buyer_currency_seller_with_product(price_cents: 1500)
      activate_buyer_currency_flags(seller)
      allow(Stripe).to receive(:api_key).and_return("sk_test_currency")
      stub_geoip_country("104.28.0.1", "United States")

      props = stripe_payment_props(add_products: [checkout_product_for(product)], ip: "104.28.0.1")

      expect(props[:elements_options][:currency]).to eq("eur")
      expect(props[:elements_options][:payment_method_types]).not_to include("cashapp", "us_bank_account")
      expect(props[:elements_options][:payment_method_types]).to include("ideal", "bancontact")
    ensure
      deactivate_buyer_currency_flags(seller) if seller
    end

    it "keeps the USD element for a two-item cart — the QA surface only supports a single item" do
      seller, product = buyer_currency_seller_with_product(price_cents: 1500)
      other_product = create(:product, user: seller, price_currency_type: "eur", price_cents: 1500)
      activate_buyer_currency_flags(seller)
      allow(Stripe).to receive(:api_key).and_return("sk_test_currency")

      props = stripe_payment_props(add_products: [checkout_product_for(product), checkout_product_for(other_product)])

      expect(props[:elements_options][:currency]).to eq("usd")
      expect(props[:elements_options][:presentment_amount_cents]).to be_nil
    ensure
      deactivate_buyer_currency_flags(seller) if seller
    end

    it "keeps today's USD element behavior for an EUR-priced product when the buyer-currency flags are off" do
      _seller, product = buyer_currency_seller_with_product(price_cents: 1500)
      allow(Stripe).to receive(:api_key).and_return("sk_test_currency")

      expect(stripe_payment_props(add_products: [checkout_product_for(product)]))
        .to eq(payment_element_client_confirm_props)
    end

    it "falls back to CardElement for a recurring EUR-priced presentment candidate instead of crashing" do
      # A recurring cart is rejected by the payment method resolver (client-confirm only
      # covers one-time purchases), so its resolution carries a nil method list. The
      # method-forced shape check must consult the resolver's eligibility verdict before
      # scanning the method list — otherwise this cart raises instead of returning the
      # buyer_currency_presentment_unsupported fallback.
      seller = create(:user, disable_buyer_local_currency: false)
      product = create(:membership_product, user: seller, price_currency_type: "eur", price_cents: 1500)
      Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
      Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CLIENT_CONFIRM_FEATURE_NAME, seller)
      activate_buyer_currency_flags(seller)
      allow(Stripe).to receive(:api_key).and_return("sk_test_currency")
      add_products = [
        checkout_product_for(
          product,
          # Membership products keep their price on tiers, so the checkout item's price must
          # be passed explicitly or the cart totals zero and trips the earlier not_charged
          # fallback before reaching the presentment gate this example is about.
          price: 1500,
          recurrence: "monthly",
          buyer_currency_display: {
            display_mode: "buyer_local",
            buyer_currency_shown: Currency::EUR,
          }
        )
      ]

      expect(stripe_payment_props(add_products:)).to eq(
        integration: described_class::STRIPE_CARD_ELEMENT_INTEGRATION,
        fallback_reason: "buyer_currency_presentment_unsupported",
        disable_wallets: true,
        request_apple_pay_merchant_tokens: false,
        payment_element_wallets: false,
        elements_options: nil,
      )
    ensure
      deactivate_buyer_currency_flags(seller) if seller
    end

    it "keeps the CardElement fallback for an EUR-priced product when the client-confirm flag is off" do
      seller = create(:user, disable_buyer_local_currency: false)
      product = create(:product, user: seller, price_currency_type: "eur", price_cents: 1500)
      Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
      activate_buyer_currency_flags(seller)
      allow(Stripe).to receive(:api_key).and_return("sk_test_currency")
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
        payment_element_wallets: false,
        elements_options: nil,
      )
    ensure
      deactivate_buyer_currency_flags(seller) if seller
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

  describe "Payment Element wallets flag" do
    it "enables wallets on the Payment Element integration when the seller is flagged" do
      seller = create(:user)
      product = create(:product, user: seller, price_cents: 1234)
      Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
      Feature.activate_user(described_class::PAYMENT_ELEMENT_WALLETS_FEATURE_NAME, seller)

      expect(stripe_payment_props(add_products: [checkout_product_for(product)]))
        .to eq(payment_element_props(payment_element_wallets: true))
    end

    it "enables wallets on the client-confirm integration when the seller is flagged" do
      seller = create(:user)
      product = create(:product, user: seller, price_cents: 1234)
      Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
      Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CLIENT_CONFIRM_FEATURE_NAME, seller)
      Feature.activate_user(described_class::PAYMENT_ELEMENT_WALLETS_FEATURE_NAME, seller)

      expect(stripe_payment_props(add_products: [checkout_product_for(product)]))
        .to eq(payment_element_client_confirm_props(payment_element_wallets: true))
    end

    it "never enables element wallets on the CardElement fallback, even when the seller is flagged" do
      # CardElement carts (installment plans and other fallbacks) never mount a Payment Element,
      # so there is no element wallet surface to enable — they keep the Payment Request Button.
      seller = create(:user)
      product = create(:product, user: seller, price_cents: 1234)
      Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
      Feature.activate_user(described_class::PAYMENT_ELEMENT_WALLETS_FEATURE_NAME, seller)

      expect(stripe_payment_props(add_products: [checkout_product_for(product, pay_in_installments: true)]))
        .to eq(card_element_fallback("setup_or_installment_flow"))
    end

    it "keeps element wallets off when the cart disables wallets, even with the seller flagged" do
      # The method-forced buyer-currency QA shape reaches client-confirm with disable_wallets:
      # true (a wallet payment would charge through the canonical USD path while the cart shows
      # buyer-currency totals). The constraint is server-owned: the props must never say both
      # "wallets are disabled" and "render wallets in the element".
      seller = create(:user, disable_buyer_local_currency: false)
      product = create(:product, user: seller, price_currency_type: "eur", price_cents: 1500)
      Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
      Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CLIENT_CONFIRM_FEATURE_NAME, seller)
      Feature.activate_user(described_class::PAYMENT_ELEMENT_WALLETS_FEATURE_NAME, seller)
      Feature.activate_user(:buyer_local_currency, seller)
      Feature.activate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)
      allow(Stripe).to receive(:api_key).and_return("sk_test_currency")
      add_products = [
        checkout_product_for(
          product,
          buyer_currency_display: {
            display_mode: "buyer_local",
            buyer_currency_shown: Currency::CAD,
          }
        )
      ]

      props = stripe_payment_props(add_products:)

      expect(props[:integration]).to eq(described_class::STRIPE_PAYMENT_ELEMENT_CLIENT_CONFIRM_INTEGRATION)
      expect(props[:disable_wallets]).to be(true)
      expect(props[:payment_element_wallets]).to be(false)
    ensure
      if seller
        Feature.deactivate_user(:buyer_local_currency, seller)
        Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)
      end
    end

    it "does not enable wallets when the seller is not flagged" do
      expect(stripe_payment_props(add_products: [flagged_seller_product]))
        .to eq(payment_element_props(payment_element_wallets: false))
    end

    it "does not enable wallets when any seller in the cart is not flagged" do
      # Seller-complete keying: turning the flag on for one seller must never change another
      # seller's checkout.
      flagged_seller = create(:user)
      flagged = create(:product, user: flagged_seller, price_cents: 1234)
      Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, flagged_seller)
      Feature.activate_user(described_class::PAYMENT_ELEMENT_WALLETS_FEATURE_NAME, flagged_seller)
      unflagged_seller = create(:user)
      unflagged = create(:product, user: unflagged_seller, price_cents: 1234)
      Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, unflagged_seller)

      expect(stripe_payment_props(add_products: [checkout_product_for(flagged), checkout_product_for(unflagged)]))
        .to eq(payment_element_props(payment_element_wallets: false))
    end
  end
end
