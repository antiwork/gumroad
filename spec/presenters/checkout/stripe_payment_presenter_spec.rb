# frozen_string_literal: true

describe Checkout::StripePaymentPresenter do
  def checkout_product_for(product, price: product.price_cents, recurrence: nil, pay_in_installments: false,
                           is_preorder: product.is_in_preorder_state, free_trial: product.free_trial_enabled,
                           native_type: product.native_type)
    {
      product: {
        creator: { id: product.user.external_id },
        is_preorder:,
        free_trial: free_trial ? { duration: { unit: "day", amount: 1 } } : nil,
        native_type:,
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

  def card_element_fallback(reason)
    { integration: described_class::STRIPE_CARD_ELEMENT_INTEGRATION, fallback_reason: reason, elements_options: nil }
  end

  def payment_element_props(stripe_elements_mode: described_class::STRIPE_ELEMENTS_MODE_FOR_PAYMENT_INTENT, stripe_link_enabled: false)
    {
      integration: described_class::STRIPE_PAYMENT_ELEMENT_INTEGRATION,
      fallback_reason: nil,
      elements_options: {
        stripe_elements_mode:,
        currency: "usd",
        payment_method_types: ["card"],
        payment_method_creation: "manual",
        stripe_link_enabled:,
      },
    }
  end

  def stripe_payment_props(cart: nil, add_products: [], clear_cart: false, saved_credit_card: nil)
    described_class.new(cart:, add_products:, clear_cart:, saved_credit_card:).props
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

  it "keeps Link disabled in the Payment Element when only the Payment Element flag is enabled" do
    expect(stripe_payment_props(add_products: [flagged_seller_product])).to eq(payment_element_props(stripe_link_enabled: false))
  end

  it "enables Link in the Payment Element when the seller has the Link flag enabled" do
    seller = create(:user)
    product = create(:product, user: seller, price_cents: 1234)
    Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
    Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_LINK_FEATURE_NAME, seller)

    expect(stripe_payment_props(add_products: [checkout_product_for(product)])).to eq(payment_element_props(stripe_link_enabled: true))
  end

  it "does not render the Payment Element when the Link flag is enabled but the Payment Element flag is not" do
    seller = create(:user)
    product = create(:product, user: seller, price_cents: 1234)
    Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_LINK_FEATURE_NAME, seller)

    expect(stripe_payment_props(add_products: [checkout_product_for(product)]))
      .to eq(card_element_fallback("stripe_payment_element_flag_disabled"))
  end
end
