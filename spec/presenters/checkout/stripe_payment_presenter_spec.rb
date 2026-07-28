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
    { integration: described_class::STRIPE_CARD_ELEMENT_INTEGRATION, fallback_reason: reason, disable_wallets: false, request_apple_pay_merchant_tokens:, payment_element_wallets: false, flat_payment_methods: false, elements_options: nil }
  end

  # The Element's Link toggle and the intent's method list derive from the same resolver output, so
  # they move together; Link is always launched, and the US-locked methods (cashapp/us_bank_account)
  # are passed explicitly by the region-gate specs.
  def payment_element_client_confirm_props(stripe_link_enabled: true, payment_method_types: %w[card link], stripe_connect_account_id: nil, currency: "usd", presentment_amount_cents: nil, listed_currency_display: nil, disable_wallets: false, request_apple_pay_merchant_tokens: false, payment_element_wallets: false, flat_payment_methods: payment_element_wallets || disable_wallets)
    {
      integration: described_class::STRIPE_PAYMENT_ELEMENT_CLIENT_CONFIRM_INTEGRATION,
      fallback_reason: nil,
      disable_wallets:,
      request_apple_pay_merchant_tokens:,
      payment_element_wallets:,
      flat_payment_methods:,
      elements_options: {
        stripe_elements_mode: described_class::STRIPE_ELEMENTS_MODE_FOR_PAYMENT_INTENT,
        currency:,
        presentment_amount_cents:,
        # Every method-forced element mounts in a non-USD currency, so it also tells the checkout
        # summary to render that currency. Defaults to the forced currency at the standard 1/100
        # minor-unit scale, which covers EUR/BRL/INR; pass it explicitly for anything else.
        listed_currency_display: listed_currency_display ||
          (currency == "usd" ? nil : { currency:, subunit_to_unit: 100 }),
        payment_method_types:,
        stripe_link_enabled:,
        stripe_connect_account_id:,
      },
    }
  end

  def payment_element_props(stripe_elements_mode: described_class::STRIPE_ELEMENTS_MODE_FOR_PAYMENT_INTENT, stripe_link_enabled: true, request_apple_pay_merchant_tokens: false, buyer_currency_presentment: false, disable_wallets: false, payment_element_wallets: false, flat_payment_methods: payment_element_wallets || disable_wallets)
    {
      integration: described_class::STRIPE_PAYMENT_ELEMENT_INTEGRATION,
      fallback_reason: nil,
      disable_wallets:,
      request_apple_pay_merchant_tokens:,
      payment_element_wallets:,
      flat_payment_methods:,
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

  # The gumroad-private#1436 ramp. Wallets on this lane are safe because the element's wallet
  # sheet quotes the same locked buyer-currency total the cart displays, but they ride their own
  # flag so an emergency ramp-down does not remove wallets from every other checkout.
  describe "wallets on the buyer-currency presentment lane" do
    let(:presentment_seller) { create(:user, disable_buyer_local_currency: false) }
    let(:presentment_product) { create(:product, user: presentment_seller, price_cents: 1234) }
    let(:presentment_add_products) do
      [
        checkout_product_for(
          presentment_product,
          buyer_currency_display: { display_mode: "buyer_local", buyer_currency_shown: Currency::CAD }
        )
      ]
    end

    before do
      allow(Stripe).to receive(:api_key).and_return("sk_test_currency")
      Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, presentment_seller)
      Feature.activate_user(:buyer_local_currency, presentment_seller)
      Feature.activate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, presentment_seller)
    end

    after do
      Feature.deactivate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, presentment_seller)
      Feature.deactivate_user(:buyer_local_currency, presentment_seller)
      Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, presentment_seller)
      Feature.deactivate_user(described_class::PAYMENT_ELEMENT_WALLETS_FEATURE_NAME, presentment_seller)
      Feature.deactivate_user(described_class::BUYER_CURRENCY_WALLETS_FEATURE_NAME, presentment_seller)
    end

    it "enables wallets when both the general wallet flag and this lane's ramp are active" do
      Feature.activate_user(described_class::PAYMENT_ELEMENT_WALLETS_FEATURE_NAME, presentment_seller)
      Feature.activate_user(described_class::BUYER_CURRENCY_WALLETS_FEATURE_NAME, presentment_seller)

      expect(stripe_payment_props(add_products: presentment_add_products)).to eq(
        payment_element_props(buyer_currency_presentment: true, disable_wallets: false, payment_element_wallets: true)
      )
    end

    # The lane's own kill switch: pulling this flag removes wallets from presentment carts while
    # leaving them on every other checkout the general flag governs.
    it "keeps wallets suppressed when this lane's ramp is off but the general wallet flag is on" do
      Feature.activate_user(described_class::PAYMENT_ELEMENT_WALLETS_FEATURE_NAME, presentment_seller)

      expect(stripe_payment_props(add_products: presentment_add_products)).to eq(
        payment_element_props(buyer_currency_presentment: true, disable_wallets: true)
      )
    end

    # And the general flag still dominates: ramping it down must remove wallets everywhere,
    # including here, no matter what this lane's flag says.
    it "keeps wallets suppressed when the general wallet flag is off even with this lane's ramp on" do
      Feature.activate_user(described_class::BUYER_CURRENCY_WALLETS_FEATURE_NAME, presentment_seller)

      expect(stripe_payment_props(add_products: presentment_add_products)).to eq(
        payment_element_props(buyer_currency_presentment: true, disable_wallets: true)
      )
    end

    # A cart that falls back to CardElement never mounts a Payment Element, so its only wallet
    # surface is the Payment Request Button — whose sheet shows canonical USD. It stays suppressed
    # regardless of either flag.
    it "keeps wallets suppressed on a CardElement-fallback presentment cart with both flags on" do
      Feature.activate_user(described_class::PAYMENT_ELEMENT_WALLETS_FEATURE_NAME, presentment_seller)
      Feature.activate_user(described_class::BUYER_CURRENCY_WALLETS_FEATURE_NAME, presentment_seller)
      # A recurring item is a presentment candidate but not a supported element shape.
      recurring_product = create(:membership_product, user: presentment_seller)
      add_products = [
        checkout_product_for(
          recurring_product,
          price: 500,
          recurrence: "monthly",
          buyer_currency_display: { display_mode: "buyer_local", buyer_currency_shown: Currency::CAD }
        )
      ]

      props = stripe_payment_props(add_products:)

      expect(props[:integration]).to eq(described_class::STRIPE_CARD_ELEMENT_INTEGRATION)
      expect(props[:disable_wallets]).to be(true)
      expect(props[:payment_element_wallets]).to be(false)
    end
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
      flat_payment_methods: false,
      elements_options: nil,
    )
  ensure
    (sellers || []).each do |seller|
      Feature.deactivate_user(:buyer_local_currency, seller)
      Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)
    end
  end

  it "selects the buyer-currency presentment Payment Element for a cart priced in a currency other than the buyer's" do
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
    # The seller pricing one item in euros says nothing about what a Canadian buyer is
    # quoted: the quote converts the cart's canonical USD total into the buyer's currency
    # either way, so both items present in CAD.
    add_products = [
      checkout_product_for(product, buyer_currency_display:),
      checkout_product_for(eur_product, buyer_currency_display:),
    ]

    expect(stripe_payment_props(add_products:)).to eq(
      payment_element_props(buyer_currency_presentment: true, disable_wallets: true)
    )
  ensure
    Feature.deactivate_user(:buyer_local_currency, seller) if seller
    Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller) if seller
  end

  it "falls back to CardElement when an item is already priced in the buyer's own currency" do
    seller = create(:user, disable_buyer_local_currency: false)
    product = create(:product, user: seller, price_cents: 1234)
    cad_product = create(:product, user: seller, price_currency_type: "cad", price_cents: 500)
    allow(Stripe).to receive(:api_key).and_return("sk_test_currency")
    Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
    Feature.activate_user(:buyer_local_currency, seller)
    Feature.activate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)
    # A product already priced in the buyer's currency has nothing to convert, so its
    # buyer-local display stays off (buyer_currency_display_props returns "default" when
    # the two currencies match) and it is not a presentment candidate. The quote locks the
    # whole cart total, so that one item takes the whole cart back to canonical USD —
    # which is right here, because quoting that item would round-trip its listed CAD
    # price through two FX rates and charge the buyer an amount that drifts from the
    # price on the page.
    add_products = [
      checkout_product_for(product, buyer_currency_display: { display_mode: "buyer_local", buyer_currency_shown: Currency::CAD }),
      checkout_product_for(cad_product, buyer_currency_display: { display_mode: "default", buyer_currency_shown: Currency::CAD }),
    ]

    expect(stripe_payment_props(add_products:)).to eq(
      integration: described_class::STRIPE_CARD_ELEMENT_INTEGRATION,
      fallback_reason: "buyer_currency_presentment_unsupported",
      disable_wallets: true,
      request_apple_pay_merchant_tokens: false,
      payment_element_wallets: false,
      flat_payment_methods: false,
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
      flat_payment_methods: false,
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
      flat_payment_methods: false,
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
      flat_payment_methods: false,
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

    describe "Klarna launch flag (checkout_local_method_klarna)" do
      def klarna_flagged_seller_item(**overrides)
        item = confirm_flagged_seller_product(**overrides)
        seller = User.find_by(external_id: item[:product][:creator][:id])
        Feature.activate_user(:checkout_local_method_klarna, seller)
        item
      end

      it "mounts the element with Klarna for a US buyer of a flagged seller when the cart is inside the USD window" do
        stub_geoip_country("104.28.0.1", "United States")

        expect(stripe_payment_props(add_products: [klarna_flagged_seller_item], ip: "104.28.0.1"))
          .to eq(payment_element_client_confirm_props(payment_method_types: %w[card link cashapp klarna]))
      end

      it "keeps Klarna off for a non-US buyer even with the flag on" do
        stub_geoip_country("2.2.2.2", "United Kingdom")

        expect(stripe_payment_props(add_products: [klarna_flagged_seller_item], ip: "2.2.2.2"))
          .to eq(payment_element_client_confirm_props(payment_method_types: %w[card link]))
      end

      it "keeps Klarna off a cart above Stripe's USD transaction ceiling — eligibility fails closed instead of erroring at confirm" do
        stub_geoip_country("104.28.0.1", "United States")
        item = klarna_flagged_seller_item
        item[:price] = 5_000_00

        expect(stripe_payment_props(add_products: [item], ip: "104.28.0.1"))
          .to eq(payment_element_client_confirm_props(payment_method_types: %w[card link cashapp]))
      end

      it "counts quantities toward the window — price is per-unit, so 100 × $50 is a $5,000 cart, not a $50 one" do
        stub_geoip_country("104.28.0.1", "United States")
        item = klarna_flagged_seller_item
        item[:price] = 50_00
        item[:quantity] = 100

        expect(stripe_payment_props(add_products: [item], ip: "104.28.0.1"))
          .to eq(payment_element_client_confirm_props(payment_method_types: %w[card link cashapp]))
      end

      # The example above covers the buy-now/upsell path, which carries quantity in the
      # add_products hash. The shopping-cart path reads it from the CartProduct row instead, so
      # it needs its own pin: without it, dropping quantity from the cart branch would price a
      # 100 × $50 cart as $50 and render Klarna on a $5,000 cart while every other spec passed.
      it "counts CartProduct quantities toward the window on the shopping-cart path" do
        stub_geoip_country("104.28.0.1", "United States")
        seller = create(:user)
        product = create(:product, user: seller, price_cents: 50_00)
        Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
        Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CLIENT_CONFIRM_FEATURE_NAME, seller)
        Feature.activate_user(:checkout_local_method_klarna, seller)
        cart = create(:cart, :guest)
        create(:cart_product, cart:, product:, price: 50_00, quantity: 100)

        expect(stripe_payment_props(cart:, ip: "104.28.0.1"))
          .to eq(payment_element_client_confirm_props(payment_method_types: %w[card link cashapp]))
      end

      # Multi-item single-seller carts are Klarna-eligible (the gate is sellers.one?, not
      # items.one?) and the window input must be the SUM across items — these branches decide
      # real eligibility, so pin them rather than leaving the derivation to the resolver
      # spec's injected totals.
      it "offers Klarna on a multi-item single-seller USD cart whose summed total is inside the window" do
        stub_geoip_country("104.28.0.1", "United States")
        first_item = klarna_flagged_seller_item
        seller = User.find_by(external_id: first_item[:product][:creator][:id])
        second_product = create(:product, user: seller, price_cents: 20_00)
        second_item = checkout_product_for(second_product)

        expect(stripe_payment_props(add_products: [first_item, second_item], ip: "104.28.0.1"))
          .to eq(payment_element_client_confirm_props(payment_method_types: %w[card link cashapp klarna]))
      end

      it "keeps Klarna off a multi-item single-seller cart whose SUMMED total crosses the ceiling, even though each item alone is inside the window" do
        stub_geoip_country("104.28.0.1", "United States")
        first_item = klarna_flagged_seller_item
        first_item[:price] = 3_000_00
        seller = User.find_by(external_id: first_item[:product][:creator][:id])
        second_product = create(:product, user: seller, price_cents: 3_000_00)
        second_item = checkout_product_for(second_product)

        expect(stripe_payment_props(add_products: [first_item, second_item], ip: "104.28.0.1"))
          .to eq(payment_element_client_confirm_props(payment_method_types: %w[card link cashapp]))
      end

      # A cart containing any non-USD-priced item nils the window input, which fails closed
      # for Klarna — Stripe's Klarna window is defined on USD amounts, so a total we cannot
      # express in USD must never render the method.
      it "keeps Klarna off a cart with a non-USD-priced item — the window input is nil and fails closed" do
        stub_geoip_country("104.28.0.1", "United States")
        first_item = klarna_flagged_seller_item
        seller = User.find_by(external_id: first_item[:product][:creator][:id])
        eur_product = create(:product, user: seller, price_cents: 10_00, price_currency_type: "eur")
        eur_item = checkout_product_for(eur_product)

        props = stripe_payment_props(add_products: [first_item, eur_item], ip: "104.28.0.1")

        expect(props[:elements_options][:payment_method_types]).not_to include("klarna")
      end
    end

    it "keeps Klarna off without its launch flag — the flag defaults to 0% everywhere" do
      stub_geoip_country("104.28.0.1", "United States")

      expect(stripe_payment_props(add_products: [confirm_flagged_seller_product], ip: "104.28.0.1"))
        .to eq(payment_element_client_confirm_props(payment_method_types: %w[card link cashapp]))
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
    let(:platform_merchant_account) do
      # CI databases don't always seed the Gumroad-managed Stripe platform account. Make
      # an existing seed match this test's USD-holding premise too, so its result does not
      # depend on how another suite configured that shared account.
      MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id)&.tap do |account|
        account.update!(charge_processor_merchant_id: "acct_gumroad", currency: Currency::USD)
      end ||
        create(:merchant_account, user: nil, charge_processor_merchant_id: "acct_gumroad", currency: Currency::USD)
    end

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

    it "mounts the buyer-currency element, not the forced-currency one, for a Canadian buyer of an EUR-priced product" do
      seller, product = buyer_currency_seller_with_product(price_cents: 1500)
      activate_buyer_currency_flags(seller)
      allow(Stripe).to receive(:api_key).and_return("sk_test_currency")
      # Referenced so the forced-currency methods really are on offer for this cart (see the
      # note in the matched-currency example below). Without it the resolver returns no local
      # methods, the cart is not method-forced at all, and the example would pass without
      # exercising the overlap it exists to pin.
      platform_merchant_account
      add_products = [
        checkout_product_for(
          product,
          buyer_currency_display: {
            display_mode: "buyer_local",
            buyer_currency_shown: Currency::CAD,
          }
        )
      ]

      # This cart is both shapes at once: an EUR listing carries the forced local methods, and
      # a Canadian buyer of it is an ordinary quote candidate. It must take the quote lane. The
      # surcharge endpoint quotes this cart, so the checkout shows CA$ totals and submits the
      # quote token — and the client-confirm lane rejects any request carrying a token
      # (Order::PreparePaymentIntentService#block_unexpected_buyer_currency_quote), which would
      # fail every payment attempt. Giving up the iDEAL/Bancontact tabs costs this buyer
      # nothing: both methods need a bank in the country that issues them.
      expect(stripe_payment_props(add_products:)).to eq(
        payment_element_props(buyer_currency_presentment: true, disable_wallets: true)
      )
    ensure
      deactivate_buyer_currency_flags(seller) if seller
    end

    it "keeps the forced-currency element for a buyer whose own currency is the listed one" do
      seller, product = buyer_currency_seller_with_product(price_cents: 1500)
      activate_buyer_currency_flags(seller)
      allow(Stripe).to receive(:api_key).and_return("sk_test_currency")
      # Referenced so the USD-holding platform account exists: the resolver only offers the
      # forced-currency methods when it does (forced_currency_settlement_supported?), and the
      # lazy let above means an example that never touches it depends on how the database
      # happened to be seeded.
      platform_merchant_account
      # A Dutch buyer of a EUR product — the shape #6346 is about. The currencies match, so
      # buyer_currency_display_props yields display_mode "default", no quote is created, and
      # nothing is submitted for prepare to reject. This cart must keep the forced-currency
      # element and its local method tabs: it is what makes iDEAL reachable at all.
      add_products = [
        checkout_product_for(
          product,
          buyer_currency_display: {
            display_mode: "default",
            buyer_currency_shown: Currency::EUR,
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

    it "never mounts the client-confirm element for a cart Checkout::BuyerCurrencyQuote would really quote" do
      # The two examples above pin the routing against a hand-written expectation of which carts
      # get quoted. This one asserts the underlying rule against the quote service ITSELF, so the
      # pair cannot silently drift apart: if quotable_product? is ever widened to cover a cart the
      # method-forced lane still claims, this reddens even though both examples above still pass.
      # What makes it load-bearing is that the combination is unpayable, not merely suboptimal —
      # a quoted cart submits a token and client-confirm prepare fails closed on one
      # (Order::PreparePaymentIntentService#block_unexpected_buyer_currency_quote).
      seller, product = buyer_currency_seller_with_product(price_cents: 1500)
      activate_buyer_currency_flags(seller)
      allow(Stripe).to receive(:api_key).and_return("sk_test_currency")
      platform_merchant_account
      # The buyer's currency comes from GeoIP and the FX rate from Stripe; neither is what this
      # example is about, so both are stubbed exactly as the quote service's own spec does.
      allow_any_instance_of(Checkout::BuyerCurrencyQuote)
        .to receive(:buyer_currency_for_ip).and_return(Currency::CAD)
      allow(StripeFxQuote).to receive(:create).and_return(
        StripeFxQuote::Quote.new(id: "fxq_test", expires_at: 30.minutes.from_now, fx_rate: BigDecimal("0.7"))
      )

      line_item = Checkout::BuyerCurrencyQuote::LineItem.new(
        permalink: product.unique_permalink, product:, price_cents: 1630,
        tip_cents: 0, seller_tax_cents: 0, gumroad_tax_cents: 0, shipping_cents: 0
      )
      quote = Checkout::BuyerCurrencyQuote.create(
        line_items: [line_item], canonical_total_cents: 1630, ip: "24.48.0.1"
      )
      # Guard the guard: if this EUR listing stopped being quotable the assertion below would
      # pass vacuously and the rule would no longer be under test.
      expect(quote).to be_present
      expect(quote.currency).to eq(Currency::CAD)

      add_products = [
        checkout_product_for(
          product,
          buyer_currency_display: { display_mode: "buyer_local", buyer_currency_shown: Currency::CAD }
        )
      ]

      expect(stripe_payment_props(add_products:)[:integration])
        .not_to eq(described_class::STRIPE_PAYMENT_ELEMENT_CLIENT_CONFIRM_INTEGRATION)
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

    it "keeps the iDEAL tab on the EUR element even when the platform account has learned an EUR settlement mismatch" do
      # The learned mismatch marker only predicts that an FX quote (EUR -> USD) would be
      # rejected. This cart is the direct-listed-amount shape — an EUR-priced product
      # charged at its listed price with no FX quote — so the marker must not withhold
      # the method. Suppressing the tab here is what turned iDEAL dark platform-wide on
      # 2026-07-23: enabling the iDEAL/SEPA capabilities makes the platform account
      # settle EUR in EUR, so the marker being set is the EXPECTED state once the
      # method is live (gumroad-private#933).
      seller, product = buyer_currency_seller_with_product(price_cents: 1500)
      activate_buyer_currency_flags(seller)
      Feature.activate_user(:checkout_local_method_ideal, seller)
      allow(Stripe).to receive(:api_key).and_return("sk_live_currency")
      platform_merchant_account.record_settlement_currency_mismatch!(Currency::EUR)

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

    it "mounts the INR element with UPI for a multi-item INR cart" do
      seller, product = buyer_currency_seller_with_product(price_currency_type: "inr", price_cents: 7300)
      other_product = create(:product, user: seller, price_currency_type: Currency::INR, price_cents: 7300)
      activate_buyer_currency_flags(seller)
      Feature.activate_user(:checkout_local_method_upi, seller)
      allow(Stripe).to receive(:api_key).and_return("sk_live_currency")
      stub_geoip_country("203.0.113.12", "India")

      expect(
        stripe_payment_props(
          add_products: [checkout_product_for(product), checkout_product_for(other_product)],
          ip: "203.0.113.12"
        )
      ).to eq(
        payment_element_client_confirm_props(
          currency: "inr",
          presentment_amount_cents: 14600,
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

    it "mounts the forced-currency element for a two-item cart uniformly priced in that currency" do
      seller, product = buyer_currency_seller_with_product(price_cents: 1500)
      other_product = create(:product, user: seller, price_currency_type: "eur", price_cents: 1500)
      activate_buyer_currency_flags(seller)
      allow(Stripe).to receive(:api_key).and_return("sk_test_currency")

      props = stripe_payment_props(add_products: [checkout_product_for(product), checkout_product_for(other_product)])

      expect(props[:elements_options][:currency]).to eq("eur")
      expect(props[:elements_options][:presentment_amount_cents]).to eq(3000)
      # The multi-item forced-currency lane charges the listed prices directly too, so the cart
      # summary must render in EUR rather than an FX-converted USD figure.
      expect(props[:elements_options][:listed_currency_display]).to eq(currency: "eur", subunit_to_unit: 100)
    ensure
      deactivate_buyer_currency_flags(seller) if seller
    end

    # Companion to Order::PreparePaymentIntentService's "free differently priced line" example.
    # A free USD line still renders in the Element's cart, so the Element cannot mount in EUR —
    # and prepare derives its currency basis from the same full item list. If the presenter
    # ignored free lines the browser would mint an EUR token for a USD intent (or vice versa),
    # which Stripe rejects, so presenter and prepare must agree on this cart shape.
    it "keeps the canonical USD element when a free USD line makes an otherwise-EUR cart non-uniform" do
      seller, product = buyer_currency_seller_with_product(price_cents: 1500)
      free_product = create(:product, user: seller, price_currency_type: "usd", price_cents: 0)
      activate_buyer_currency_flags(seller)
      allow(Stripe).to receive(:api_key).and_return("sk_test_currency")

      props = stripe_payment_props(
        add_products: [checkout_product_for(product), checkout_product_for(free_product, price: 0)]
      )

      expect(props[:elements_options][:currency]).to eq("usd")
      expect(props[:elements_options][:presentment_amount_cents]).to be_nil
      expect(props[:elements_options][:listed_currency_display]).to be_nil
      expect(props[:elements_options][:payment_method_types]).to eq(%w[card link])
    ensure
      deactivate_buyer_currency_flags(seller) if seller
    end

    it "keeps the canonical USD element for a mixed EUR/USD paid cart" do
      seller, product = buyer_currency_seller_with_product(price_cents: 1500)
      usd_product = create(:product, user: seller, price_currency_type: "usd", price_cents: 1500)
      activate_buyer_currency_flags(seller)
      allow(Stripe).to receive(:api_key).and_return("sk_test_currency")

      props = stripe_payment_props(
        add_products: [checkout_product_for(product), checkout_product_for(usd_product)]
      )

      expect(props[:elements_options][:currency]).to eq("usd")
      expect(props[:elements_options][:presentment_amount_cents]).to be_nil
      expect(props[:elements_options][:payment_method_types]).to eq(%w[card link])
    ensure
      deactivate_buyer_currency_flags(seller) if seller
    end

    # price_cents is the per-unit listed price, while the charge side derives the intent's amount
    # from displayed_price_cents (already quantity-inclusive). Without the multiplication a cart
    # of two EUR 15 copies would mount the Element with 1500 and confirm against a 3000 intent,
    # which Stripe rejects — so pin both paths that carry quantity.
    it "includes quantities in the forced-currency element amount on the buy-now path" do
      seller, product = buyer_currency_seller_with_product(price_cents: 1500)
      activate_buyer_currency_flags(seller)
      allow(Stripe).to receive(:api_key).and_return("sk_test_currency")

      item = checkout_product_for(product)
      item[:quantity] = 2

      props = stripe_payment_props(add_products: [item])

      expect(props[:elements_options][:currency]).to eq("eur")
      expect(props[:elements_options][:presentment_amount_cents]).to eq(3000)
    ensure
      deactivate_buyer_currency_flags(seller) if seller
    end

    it "includes CartProduct quantities in the forced-currency element amount on the shopping-cart path" do
      seller, product = buyer_currency_seller_with_product(price_cents: 1500)
      activate_buyer_currency_flags(seller)
      allow(Stripe).to receive(:api_key).and_return("sk_test_currency")
      cart = create(:cart, :guest)
      create(:cart_product, cart:, product:, price: 1500, quantity: 2)

      props = stripe_payment_props(cart:)

      expect(props[:elements_options][:currency]).to eq("eur")
      expect(props[:elements_options][:presentment_amount_cents]).to eq(3000)
    ensure
      deactivate_buyer_currency_flags(seller) if seller
    end

    it "tells the checkout summary to render the listed currency whenever the element mounts in it" do
      # The buyer is charged the listed price directly on this lane
      # (Charge::MethodForcedPresentment#direct_listed_amount_result) and there is no FX quote in
      # the surcharge response, so without this the checkout summary divided the listed price by
      # our own USD exchange rate: an INR-priced product showed a US$ cart total next to a Stripe
      # sheet about to charge rupees (gumroad-private#1371). The same defect hits every
      # forced-currency method — iDEAL (EUR), UPI (INR), Pix (BRL) once launched.
      seller, product = buyer_currency_seller_with_product(price_currency_type: "inr", price_cents: 499_000)
      activate_buyer_currency_flags(seller)
      Feature.activate_user(:checkout_local_method_upi, seller)
      allow(Stripe).to receive(:api_key).and_return("sk_live_currency")
      stub_geoip_country("203.0.113.10", "India")

      props = stripe_payment_props(add_products: [checkout_product_for(product)], ip: "203.0.113.10")

      expect(props[:elements_options][:currency]).to eq("inr")
      expect(props[:elements_options][:presentment_amount_cents]).to eq(499_000)
      # Same currency as the element mount and the charge, carrying the backend's own minor-unit
      # scale so the browser never has to guess how to denominate it.
      expect(props[:elements_options][:listed_currency_display]).to eq(currency: "inr", subunit_to_unit: 100)
    ensure
      if seller
        Feature.deactivate_user(:checkout_local_method_upi, seller)
        deactivate_buyer_currency_flags(seller)
      end
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
        flat_payment_methods: false,
        elements_options: nil,
      )
    ensure
      deactivate_buyer_currency_flags(seller) if seller
    end

    it "mounts the buyer-currency element for an EUR-priced product when the client-confirm flag is off" do
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

      # Without the client-confirm flag the iDEAL surface is unreachable, but this Canadian
      # buyer of a EUR-priced product is still an ordinary quote candidate: the cart's
      # canonical USD total converts into CAD exactly as a USD-priced cart's would
      # It used to dead-end on CardElement because quoting refused
      # any non-USD listing.
      expect(stripe_payment_props(add_products:)).to eq(
        payment_element_props(buyer_currency_presentment: true, disable_wallets: true)
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
      #
      # The buyer-local display here is the LISTED currency, i.e. no display at all, which is
      # what keeps this cart on the method-forced lane. A EUR listing shown to a buyer quoted in
      # some other currency now takes the buyer-currency element instead (the quoted cart has to
      # get a lane that can honor its token — see the ordering in #props), so this example uses
      # the euro-zone buyer the forced lane actually serves.
      seller = create(:user, disable_buyer_local_currency: false)
      product = create(:product, user: seller, price_currency_type: "eur", price_cents: 1500)
      Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
      Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CLIENT_CONFIRM_FEATURE_NAME, seller)
      Feature.activate_user(described_class::PAYMENT_ELEMENT_WALLETS_FEATURE_NAME, seller)
      Feature.activate_user(:buyer_local_currency, seller)
      Feature.activate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)
      allow(Stripe).to receive(:api_key).and_return("sk_test_currency")
      # Ensure the Gumroad-managed Stripe platform account exists and holds USD: the resolver
      # only offers the forced-currency methods when it does
      # (PaymentMethodResolver#forced_currency_settlement_supported?), and CI databases do not
      # always seed it. Without this the cart is not method-forced at all and the example would
      # assert client-confirm for the wrong reason. Inlined rather than shared because the
      # equivalent `let` lives in the method-forced describe block above.
      MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id)&.tap do |account|
        account.update!(charge_processor_merchant_id: "acct_gumroad", currency: Currency::USD)
      end ||
        create(:merchant_account, user: nil, charge_processor_merchant_id: "acct_gumroad", currency: Currency::USD)
      add_products = [
        checkout_product_for(
          product,
          buyer_currency_display: {
            display_mode: "default",
            buyer_currency_shown: Currency::EUR,
          }
        )
      ]

      props = stripe_payment_props(add_products:)

      expect(props[:integration]).to eq(described_class::STRIPE_PAYMENT_ELEMENT_CLIENT_CONFIRM_INTEGRATION)
      expect(props[:disable_wallets]).to be(true)
      expect(props[:payment_element_wallets]).to be(false)
      # The flat list is decoupled from the wallet flag: this wallet-suppressed cart still
      # renders the accordion payment-method list, just without wallet rows.
      expect(props[:flat_payment_methods]).to be(true)
    ensure
      if seller
        Feature.deactivate_user(:buyer_local_currency, seller)
        Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)
      end
    end

    it "does not enable wallets when the seller is not flagged" do
      # flat_payment_methods false is asserted explicitly: with the wallet flag off on a
      # wallet-capable cart, the kill-switch invariant requires the legacy layout (where the
      # Payment Request Button renders) to come back, not a flat list without wallets.
      expect(stripe_payment_props(add_products: [flagged_seller_product]))
        .to eq(payment_element_props(payment_element_wallets: false, flat_payment_methods: false))
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
        .to eq(payment_element_props(payment_element_wallets: false, flat_payment_methods: false))
    end
  end
end
