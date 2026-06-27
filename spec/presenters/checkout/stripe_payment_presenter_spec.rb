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

  def payment_element_props
    {
      integration: described_class::STRIPE_PAYMENT_ELEMENT_INTEGRATION,
      fallback_reason: nil,
      elements_options: {
        mode: "payment",
        currency: "usd",
        payment_method_types: ["card"],
        payment_method_creation: "manual",
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

  it "falls back to CardElement when the Stripe Payment Element seller flag is disabled" do
    product = create(:product, price_cents: 1234)

    expect(stripe_payment_props(add_products: [checkout_product_for(product)]))
      .to eq(card_element_fallback("stripe_payment_element_flag_disabled"))
  end

  it "falls back to CardElement for multi-seller carts" do
    cart = create(:cart, :guest)
    products = [
      create(:product, user: create(:user), price_cents: 100),
      create(:product, user: create(:user), price_cents: 200),
    ]
    products.each do |product|
      Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, product.user)
      create(:cart_product, cart:, product:)
    end

    expect(stripe_payment_props(cart:)).to eq(card_element_fallback("multi_seller_cart"))
  end

  it "falls back to CardElement for an empty checkout" do
    expect(stripe_payment_props).to eq(card_element_fallback("empty_cart"))
  end

  it "falls back to CardElement when the buyer has a saved credit card" do
    expect(stripe_payment_props(add_products: [flagged_seller_product], saved_credit_card: { type: "visa" }))
      .to eq(card_element_fallback("saved_credit_card"))
  end

  it "falls back to CardElement when a checkout product's seller cannot be resolved" do
    add_products = [{ product: { creator: { id: "nonexistent-seller" }, is_preorder: false, free_trial: nil, native_type: "digital" }, price: 1234, recurrence: nil, pay_in_installments: false }]

    expect(stripe_payment_props(add_products:)).to eq(card_element_fallback("unknown_seller"))
  end

  it "falls back to CardElement for a recurring membership product" do
    expect(stripe_payment_props(add_products: [flagged_seller_product(recurrence: "monthly")]))
      .to eq(card_element_fallback("reusable_payment_method_required"))
  end

  it "falls back to CardElement for a commission product" do
    expect(stripe_payment_props(add_products: [flagged_seller_product(native_type: Link::NATIVE_TYPE_COMMISSION)]))
      .to eq(card_element_fallback("reusable_payment_method_required"))
  end

  it "falls back to CardElement for an installment-plan product" do
    expect(stripe_payment_props(add_products: [flagged_seller_product(pay_in_installments: true)]))
      .to eq(card_element_fallback("setup_or_installment_flow"))
  end

  it "falls back to CardElement for a preorder product" do
    expect(stripe_payment_props(add_products: [flagged_seller_product(is_preorder: true)]))
      .to eq(card_element_fallback("setup_or_installment_flow"))
  end

  it "falls back to CardElement for a free-trial product" do
    expect(stripe_payment_props(add_products: [flagged_seller_product(free_trial: true)]))
      .to eq(card_element_fallback("setup_or_installment_flow"))
  end

  it "falls back to CardElement when the checkout total is not positive" do
    expect(stripe_payment_props(add_products: [flagged_seller_product(price: 0)]))
      .to eq(card_element_fallback("not_charged"))
  end

  it "ignores cart products when clear_cart is set" do
    cart = create(:cart, :guest)
    create(:cart_product, cart:, product: create(:product, user: create(:user)))

    expect(stripe_payment_props(cart:, add_products: [flagged_seller_product], clear_cart: true)).to eq(payment_element_props)
  end
end
