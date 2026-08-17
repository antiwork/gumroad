# frozen_string_literal: true

describe Checkout::StripePaymentPresenter do
  # A real token carries a signature and an expiry, so it cannot be written into the whole-hash
  # fixtures below. Echoing the types instead keeps those fixtures asserting the thing the presenter
  # is actually responsible for: that the list handed to the issuer is the one the Element mounted,
  # after every strip. The signing itself is Checkout::PaymentMethodListToken's own spec.
  before do
    allow(Checkout::PaymentMethodListToken).to receive(:issue) do |payment_method_types:, sellers:|
      "issued:#{payment_method_types.join(",")}" if payment_method_types.present?
    end
  end

  def checkout_product_for(product, price: product.price_cents, recurrence: nil, pay_in_installments: false,
                           is_preorder: product.is_in_preorder_state, free_trial: product.free_trial_enabled,
                           native_type: product.native_type, buyer_currency_display: nil, ppp_details: nil,
                           pwyw: product.customizable_price? ? { suggested_price_cents: product.suggested_price_cents } : nil,
                           options: product.options, option_id: nil,
                           is_tiered_membership: product.is_tiered_membership)
    {
      product: {
        creator: { id: product.user.external_id },
        is_preorder:,
        free_trial: free_trial ? { duration: { unit: "day", amount: 1 } } : nil,
        native_type:,
        buyer_currency_display:,
        ppp_details:,
        # Set by CheckoutPresenter#product_common whenever the buyer names their own price;
        # the presenter reads it so a pay-what-you-want cart listed from zero is not mistaken
        # for a free one before the buyer has entered an amount.
        pwyw:,
        # Also set by product_common. The presenter reads it to decide whether `pwyw` above can be
        # trusted: on a tiered membership the TIER carries the pay-what-you-want flag, and the
        # product-level column `pwyw` reflects can be stale-true (see the
        # buyer_can_name_price? comment for how a membership acquires it), so the tier must win.
        is_tiered_membership:,
        # Also set by product_common. Each option carries is_pwyw from BaseVariant#to_option,
        # which is the tier-aware signal on this payload.
        options:,
        # The product's own pricing currency, mirroring CheckoutPresenter#product_common,
        # which sets currency_code on every real add_products entry.
        currency_code: product.price_currency_type.to_s.downcase,
        require_shipping: product.require_shipping?,
        installment_plan: product.installment_plan.present? ? {
          number_of_installments: product.installment_plan.number_of_installments,
          recurrence: product.installment_plan.recurrence,
        } : nil,
      },
      price:,
      recurrence:,
      pay_in_installments:,
      # The tier the buyer selected, set by CheckoutPresenter#checkout_product from the accepted
      # upsell variant or the cart item's option. nil for a product with no options to pick.
      option_id:,
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
  def payment_element_client_confirm_props(stripe_link_enabled: true, payment_method_types: %w[card link], stripe_connect_account_id: nil, currency: "usd", presentment_amount_cents: nil, listed_currency_display: nil, recurring_upi_registration: false, direct_listed_card: false, disable_wallets: false, request_apple_pay_merchant_tokens: false, payment_element_wallets: false, flat_payment_methods: payment_element_wallets || disable_wallets)
    {
      integration: described_class::STRIPE_PAYMENT_ELEMENT_CLIENT_CONFIRM_INTEGRATION,
      fallback_reason: nil,
      recurring_upi_registration:,
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
        # The presenter signs the list it mounted, so the fixture pins the post-strip list: a
        # region or amount strip that failed to reach the issuer would show up here.
        payment_method_list_token: "issued:#{payment_method_types.join(",")}",
        stripe_link_enabled:,
        stripe_connect_account_id:,
        **(direct_listed_card ? { direct_listed_card: true } : {}),
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
    country_code = Compliance::Countries.find_by_name(country_name)&.alpha2
    allow(GeoIp).to receive(:lookup).with(ip).and_return(double(country_name:, country_code:))
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
      # A cart mixing a candidate with a non-candidate line (here: a product already priced in
      # the buyer's own currency, whose display stays "default") is not a supported element shape.
      cad_product = create(:product, user: presentment_seller, price_currency_type: "cad", price_cents: 500)
      add_products = presentment_add_products + [
        checkout_product_for(
          cad_product,
          buyer_currency_display: { display_mode: "default", buyer_currency_shown: Currency::CAD }
        )
      ]

      props = stripe_payment_props(add_products:)

      expect(props[:integration]).to eq(described_class::STRIPE_CARD_ELEMENT_INTEGRATION)
      expect(props[:disable_wallets]).to be(true)
      expect(props[:payment_element_wallets]).to be(false)
    end
  end

  it "selects the buyer-currency presentment Payment Element for a cart spanning several sellers" do
    sellers = Array.new(2) { create(:user, disable_buyer_local_currency: false) }
    allow(Stripe).to receive(:api_key).and_return("sk_test_currency")
    buyer_currency_display = {
      display_mode: "buyer_local",
      buyer_currency_shown: Currency::CAD,
    }
    # Two sellers means two charges (two PaymentIntents), and the surcharge endpoint locks one
    # quote per charge before the buyer is shown a total — so the cart can present in the
    # buyer's currency, with each charge priced from its own locked amount.
    add_products = sellers.map do |seller|
      Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
      Feature.activate_user(:buyer_local_currency, seller)
      Feature.activate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)
      checkout_product_for(create(:product, user: seller, price_cents: 1234), buyer_currency_display:)
    end

    props = stripe_payment_props(add_products:)

    expect(props[:integration]).to eq(described_class::STRIPE_PAYMENT_ELEMENT_INTEGRATION)
    expect(props[:fallback_reason]).to be_nil
    expect(props[:elements_options][:buyer_currency_presentment]).to be(true)
  ensure
    (sellers || []).each do |seller|
      Feature.deactivate_user(:buyer_local_currency, seller)
      Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)
    end
  end

  it "falls back to CardElement for a cart holding more sellers than the lane quotes" do
    # The surcharge endpoint withholds the quote past this many sellers, so mounting the element
    # in the buyer's currency would only make the browser drop back to dollars a moment later.
    sellers = Array.new(Checkout::BuyerCurrencyQuote::MAX_QUOTED_CHARGES + 1) { create(:user, disable_buyer_local_currency: false) }
    allow(Stripe).to receive(:api_key).and_return("sk_test_currency")
    buyer_currency_display = {
      display_mode: "buyer_local",
      buyer_currency_shown: Currency::CAD,
    }
    add_products = sellers.map do |seller|
      Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
      Feature.activate_user(:buyer_local_currency, seller)
      Feature.activate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)
      checkout_product_for(create(:product, user: seller, price_cents: 1234), buyer_currency_display:)
    end

    props = stripe_payment_props(add_products:)

    expect(props[:integration]).to eq(described_class::STRIPE_CARD_ELEMENT_INTEGRATION)
    expect(props[:fallback_reason]).to eq("buyer_currency_presentment_unsupported")
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

  it "mounts the buyer-currency element for a one-time purchase of a product offering an installment plan" do
    # Whether the quote layer will actually quote this cart is its own policy (the display and
    # quote service gate installment-offering products on the subscription ramp); the presenter
    # only needs every line to be a candidate. An unquoted cart mounts canonical USD.
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
      payment_element_props(buyer_currency_presentment: true, disable_wallets: true)
    )
  ensure
    Feature.deactivate_user(:buyer_local_currency, seller) if seller
    Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller) if seller
  end

  it "mounts the buyer-currency element for a buyer who picked pay-in-installments on a presentment candidate" do
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
        pay_in_installments: true,
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

  it "mounts the canonical USD element for a buyer who picked pay-in-installments when the cart is not a presentment candidate" do
    expect(stripe_payment_props(add_products: [flagged_seller_product(pay_in_installments: true)]))
      .to eq(payment_element_props)
  end

  it "mounts the buyer-currency element for a recurring presentment candidate" do
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
      payment_element_props(buyer_currency_presentment: true, disable_wallets: true)
    )
  ensure
    Feature.deactivate_user(:buyer_local_currency, seller) if seller
    Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller) if seller
  end

  it "mounts the buyer-currency element for a commission presentment candidate" do
    seller = create(:user, disable_buyer_local_currency: false)
    product = create(:product, user: seller, price_cents: 1234)
    allow(Stripe).to receive(:api_key).and_return("sk_test_currency")
    Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
    Feature.activate_user(:buyer_local_currency, seller)
    Feature.activate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)
    add_products = [
      checkout_product_for(
        product,
        native_type: Link::NATIVE_TYPE_COMMISSION,
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

  it "keeps SetupIntent mode for a preorder presentment candidate" do
    # A setup cart charges nothing today, so there is no amount to present in the buyer's
    # currency; the setup branch must claim it before the presentment branch or it would mount
    # a payment-mode element on a cart with no charge.
    seller = create(:user, disable_buyer_local_currency: false)
    product = create(:product, user: seller, price_cents: 1234)
    allow(Stripe).to receive(:api_key).and_return("sk_test_currency")
    Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
    Feature.activate_user(:buyer_local_currency, seller)
    Feature.activate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)
    add_products = [
      checkout_product_for(
        product,
        is_preorder: true,
        buyer_currency_display: {
          display_mode: "buyer_local",
          buyer_currency_shown: Currency::CAD,
        }
      )
    ]

    expect(stripe_payment_props(add_products:)).to eq(
      payment_element_props(stripe_elements_mode: described_class::STRIPE_ELEMENTS_MODE_FOR_SETUP_INTENT)
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

  it "mounts the buyer-currency element for a recurring presentment candidate in live mode" do
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
      payment_element_props(buyer_currency_presentment: true, disable_wallets: true)
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

  # gumroad-private#1430. A pay-what-you-want product listed from zero reads as a zero total
  # here, because the surface is chosen when the page loads — before the buyer types an amount.
  # Treating that as "free" mounted the legacy card surface on carts buyers then paid real money
  # on, costing them the Payment Element's local methods and wallets for no reason.
  it "keeps the Payment Element for a pay-what-you-want product listed from zero" do
    seller = create(:user)
    Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
    pwyw_product = create(:product, user: seller, price_cents: 0, customizable_price: true)

    expect(stripe_payment_props(add_products: [checkout_product_for(pwyw_product, price: 0)]))
      .to eq(payment_element_props(stripe_elements_mode: described_class::STRIPE_ELEMENTS_MODE_FOR_PAYMENT_INTENT))
  end

  # The zero total is not yet the amount that will be charged, so it must not be measured
  # against Stripe's minimum either — that would reject the Payment Element on a cart the
  # buyer may well pay well above the minimum on.
  it "does not reject a zero-total pay-what-you-want cart as below the Payment Element minimum" do
    seller = create(:user)
    Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
    pwyw_product = create(:product, user: seller, price_cents: 0, customizable_price: true)

    props = stripe_payment_props(add_products: [checkout_product_for(pwyw_product, price: 0)])

    expect(props[:fallback_reason]).to be_nil
    expect(props[:integration]).to eq("payment_element")
  end

  # Keeping a pending-price cart on the Payment Element must not put it on the CLIENT-CONFIRM
  # lane, because that lane commits to a payment-method list at page load and the deferred intent
  # has to match it exactly — Stripe rejects a payment_method_types-scoped ConfirmationToken
  # against an intent with a different list, which fails the confirm for EVERY method the buyer
  # could pick, card and Link included. Klarna's gate is cart-total dependent
  # (KLARNA_MIN_USD_CHARGE_CENTS is $1), so a cart mounting at zero resolves WITHOUT Klarna while
  # Order::PreparePaymentIntentService, which re-resolves from the real purchase amounts, adds it
  # back once the buyer names an eligible amount. The server-confirm element carries a fixed
  # ["card"] list and no deferred intent, so it has nothing to drift from.
  it "keeps a pay-what-you-want cart off the client-confirm lane, where the method list would drift once an amount is named" do
    seller = create(:user)
    Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
    Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CLIENT_CONFIRM_FEATURE_NAME, seller)
    Feature.activate_user(:checkout_local_method_klarna, seller)
    pwyw_product = create(:product, user: seller, price_cents: 0, customizable_price: true)
    stub_geoip_country("104.28.0.1", "United States")

    # The premise: at $25 this same cart IS a Klarna cart on the client-confirm lane, so the two
    # lanes really would resolve different method lists across the buyer entering an amount.
    priced_props = stripe_payment_props(add_products: [checkout_product_for(pwyw_product, price: 25_00)], ip: "104.28.0.1")
    expect(priced_props[:integration]).to eq(described_class::STRIPE_PAYMENT_ELEMENT_CLIENT_CONFIRM_INTEGRATION)
    expect(priced_props[:elements_options][:payment_method_types]).to include("klarna")

    expect(stripe_payment_props(add_products: [checkout_product_for(pwyw_product, price: 0)], ip: "104.28.0.1"))
      .to eq(payment_element_props(stripe_elements_mode: described_class::STRIPE_ELEMENTS_MODE_FOR_PAYMENT_INTENT))
  ensure
    Feature.deactivate_user(:checkout_local_method_klarna, seller) if seller
  end

  # A product that genuinely cannot be paid for must keep falling back, but "free and not
  # pay-what-you-want" is not that product: Product::Prices#set_customizable_price forces
  # customizable_price to true on any $0 product, so CheckoutPresenter never emits that
  # combination — measured across 39,875 recent production products, zero of which are $0
  # with customizable_price false. Pinning it would assert on a hash production cannot
  # produce. The reachable shape is line 64's escape hatch: a $0 base product whose alive
  # variants carry a positive price_difference_cents keeps customizable_price false, and the
  # buyer pays the variant's price rather than naming their own.
  it "still falls back to CardElement for a free non-pay-what-you-want product priced by its variants" do
    seller = create(:user)
    Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
    variant_priced_product = create(:product, user: seller, price_cents: 0)
    category = create(:variant_category, link: variant_priced_product)
    create(:variant, variant_category: category, price_difference_cents: 500)
    # create(:product) already ran the callback while the product had no variants, forcing
    # customizable_price true. Clear it and re-run now that the priced variant exists, which
    # is the order a real seller produces: add the variant, then save.
    variant_priced_product.update_column(:customizable_price, false)
    variant_priced_product.send(:set_customizable_price)

    expect(variant_priced_product.reload.customizable_price).to be(false)
    expect(stripe_payment_props(add_products: [checkout_product_for(variant_priced_product, price: 0)]))
      .to eq(card_element_fallback("not_charged"))
  end

  # A tiered membership never carries the pay-what-you-want flag on the product itself:
  # Product::Prices#set_customizable_price returns early for tiered memberships and the TIER
  # carries it instead, so CheckoutPresenter#product_common emits `pwyw: nil` for every
  # membership. Reading only `pwyw` therefore left the primary buy flow (/checkout?product=…)
  # on the legacy CardElement for exactly the products this fix is about, while the same
  # product reached from a saved cart got the Payment Element. Pins the tier-aware read.
  it "keeps the Payment Element for a membership whose tier is pay-what-you-want" do
    seller = create(:user)
    Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
    membership = create(:membership_product, user: seller, price_cents: 0)
    tier = membership.tiers.first
    tier.update!(customizable_price: true)
    membership.reload

    expect(membership.customizable_price).to be_falsey
    expect(membership.has_customizable_price_option?).to be(true)

    expect(stripe_payment_props(add_products: [checkout_product_for(membership, price: 0, option_id: tier.external_id)]))
      .to eq(payment_element_props(stripe_elements_mode: described_class::STRIPE_ELEMENTS_MODE_FOR_PAYMENT_INTENT))
  end

  # The tier-aware read above must look at the tier the buyer SELECTED, not at every tier the
  # membership offers. A membership can mix a free tier with a pay-what-you-want one, and asking
  # "does any tier allow naming a price" answers yes for both — which would suppress the
  # not_charged classification on the free tier and mount the Payment Element on a checkout that
  # charges nothing. Pins the selected tier as the thing that decides.
  it "still falls back to CardElement when the selected tier is free and only another tier is pay-what-you-want" do
    seller = create(:user)
    Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
    membership = create(:membership_product, user: seller, price_cents: 0)
    free_tier = membership.tiers.first
    # Variant::Prices#set_customizable_price forces the flag true on any tier whose alive prices
    # are all zero, so clear the column directly to build the free non-pay-what-you-want tier a
    # seller reaches by pricing the tier and then zeroing it.
    free_tier.update_column(:customizable_price, false)
    pwyw_tier = create(:variant, variant_category: membership.tier_category, name: "Supporter")
    pwyw_tier.update!(customizable_price: true)
    membership.reload

    expect(free_tier.reload.customizable_price).to be(false)
    expect(membership.has_customizable_price_option?).to be(true)

    expect(stripe_payment_props(add_products: [checkout_product_for(membership, price: 0, option_id: free_tier.external_id)]))
      .to eq(card_element_fallback("not_charged"))
  ensure
    Feature.deactivate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
  end

  # The membership guard on the `pwyw` short-circuit, which is what makes the selected-tier read
  # above reachable at all. A membership can carry a stale product-level `customizable_price =
  # true`: during create, Product::Prices#write_customizable_price runs (via `price_range=`) while
  # is_tiered_membership is still false, so any membership started at $0 persists the flag, and the
  # set_customizable_price after_save callback early-returns for memberships so nothing clears it.
  # `customizable_price` is a directly writable param too. Measured on production: 6 of the 6,000
  # most recent alive products with the flag set are tiered memberships.
  #
  # Without the guard the short-circuit fires before any tier logic and mounts the Payment Element
  # on a genuinely free tier — and disagrees with cart_line_buyer_can_name_price?, which already
  # checks is_tiered_membership? first, so the same product would behave differently depending on
  # whether it came from a saved cart or /checkout?product=.
  it "ignores a stale product-level customizable_price on a membership and still reads the selected tier" do
    seller = create(:user)
    Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
    membership = create(:membership_product, user: seller, price_cents: 0)
    free_tier = membership.tiers.first
    free_tier.update_column(:customizable_price, false)
    pwyw_tier = create(:variant, variant_category: membership.tier_category, name: "Supporter")
    pwyw_tier.update!(customizable_price: true)
    # The stale flag itself. update_column so the membership early-return in the after_save
    # callback cannot interfere — which is exactly why production rows keep it.
    membership.update_column(:customizable_price, true)
    membership.reload

    # The fixture must genuinely disagree with the tier, or this example cannot distinguish the
    # guarded read from the unguarded one.
    expect(membership.customizable_price).to be(true)
    expect(free_tier.reload.customizable_price).to be(false)

    expect(stripe_payment_props(add_products: [checkout_product_for(membership, price: 0, option_id: free_tier.external_id)]))
      .to eq(card_element_fallback("not_charged"))
  ensure
    Feature.deactivate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
  end

  # The other half of the same rule: selecting the pay-what-you-want tier on that same mixed
  # membership must still reach the Payment Element, so scoping to the selected tier does not
  # undo the fix this PR exists for.
  it "keeps the Payment Element when the selected tier is the pay-what-you-want one" do
    seller = create(:user)
    Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
    membership = create(:membership_product, user: seller, price_cents: 0)
    membership.tiers.first.update_column(:customizable_price, false)
    pwyw_tier = create(:variant, variant_category: membership.tier_category, name: "Supporter")
    pwyw_tier.update!(customizable_price: true)
    membership.reload

    expect(stripe_payment_props(add_products: [checkout_product_for(membership, price: 0, option_id: pwyw_tier.external_id)]))
      .to eq(payment_element_props(stripe_elements_mode: described_class::STRIPE_ELEMENTS_MODE_FOR_PAYMENT_INTENT))
  ensure
    Feature.deactivate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
  end

  # The same rule on the saved-cart path, which reaches the presenter through a different method:
  # cart lines used Link#has_customizable_price_option?, which scans every alive tier, so a line on
  # the free tier of a mixed membership reported a customizable price and mounted the Payment
  # Element on a checkout that charges nothing. Pins the cart line's own tier as the thing that
  # decides.
  it "still falls back to CardElement when a saved cart line selects the free tier of a mixed membership" do
    seller = create(:user)
    Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
    membership = create(:membership_product, user: seller, price_cents: 0)
    free_tier = membership.tiers.first
    # Variant::Prices#set_customizable_price forces the flag true on any tier whose alive prices
    # are all zero, so clear the column directly to build the free non-pay-what-you-want tier a
    # seller reaches by pricing the tier and then zeroing it.
    free_tier.update_column(:customizable_price, false)
    pwyw_tier = create(:variant, variant_category: membership.tier_category, name: "Supporter")
    pwyw_tier.update!(customizable_price: true)
    membership.reload

    expect(membership.has_customizable_price_option?).to be(true)

    cart = create(:cart)
    create(:cart_product, cart:, product: membership, option: free_tier, price: 0)

    expect(stripe_payment_props(cart:)).to eq(card_element_fallback("not_charged"))
  ensure
    Feature.deactivate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
  end

  # The other direction on the cart path: the pay-what-you-want tier still reaches the Payment
  # Element, so scoping cart lines to their own tier does not undo the fix this PR exists for.
  it "keeps the Payment Element when a saved cart line selects the pay-what-you-want tier" do
    seller = create(:user)
    Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
    membership = create(:membership_product, user: seller, price_cents: 0)
    membership.tiers.first.update_column(:customizable_price, false)
    pwyw_tier = create(:variant, variant_category: membership.tier_category, name: "Supporter")
    pwyw_tier.update!(customizable_price: true)
    membership.reload

    cart = create(:cart)
    create(:cart_product, cart:, product: membership, option: pwyw_tier, price: 0)

    expect(stripe_payment_props(cart:))
      .to eq(payment_element_props(stripe_elements_mode: described_class::STRIPE_ELEMENTS_MODE_FOR_PAYMENT_INTENT))
  ensure
    Feature.deactivate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
  end

  # A cart line with no tier recorded is a non-tiered product, where the product's own
  # customizable_price column is authoritative and must keep holding the cart on the Payment
  # Element for a pay-what-you-want product listed from zero.
  it "keeps the Payment Element for a saved cart line on a pay-what-you-want product with no tier" do
    seller = create(:user)
    Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
    pwyw_product = create(:product, user: seller, price_cents: 0, customizable_price: true)

    cart = create(:cart)
    create(:cart_product, cart:, product: pwyw_product, price: 0)

    expect(stripe_payment_props(cart:))
      .to eq(payment_element_props(stripe_elements_mode: described_class::STRIPE_ELEMENTS_MODE_FOR_PAYMENT_INTENT))
  ensure
    Feature.deactivate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
  end

  # The guard that keeps the tier read scoped to memberships. An ordinary pay-what-you-want product
  # can also have variants, and those variants never carry the pay-what-you-want flag —
  # Variant::Prices#set_customizable_price only sets it for tiered memberships. Reading the cart
  # line's variant here would call a genuinely pay-what-you-want cart free and undo this whole fix.
  it "keeps the Payment Element for a saved cart line on a pay-what-you-want product with a variant selected" do
    seller = create(:user)
    Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
    pwyw_product = create(:product, user: seller, price_cents: 0, customizable_price: true)
    category = create(:variant_category, link: pwyw_product)
    variant = create(:variant, variant_category: category, price_difference_cents: 0)

    expect(variant.reload.customizable_price).to be_falsey
    expect(pwyw_product.reload.customizable_price).to be(true)

    cart = create(:cart)
    create(:cart_product, cart:, product: pwyw_product, option: variant, price: 0)

    expect(stripe_payment_props(cart:))
      .to eq(payment_element_props(stripe_elements_mode: described_class::STRIPE_ELEMENTS_MODE_FOR_PAYMENT_INTENT))
  ensure
    Feature.deactivate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
  end

  # A membership cart line with no tier recorded must not fall back to the product-wide tier scan.
  # Link#has_customizable_price_option? answers "does ANY alive tier allow naming a price", which is
  # exactly the product-wide question the selected-tier read exists to stop asking: an unrelated
  # pay-what-you-want tier would speak for a line that selected none, suppress the not_charged
  # classification, and mount the Payment Element on a checkout that charges nothing. A membership's
  # price can only be named through a tier, so no tier means no pending amount.
  it "still falls back to CardElement when a saved cart line on a mixed membership has no tier" do
    seller = create(:user)
    Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
    membership = create(:membership_product, user: seller, price_cents: 0)
    membership.tiers.first.update_column(:customizable_price, false)
    pwyw_tier = create(:variant, variant_category: membership.tier_category, name: "Supporter")
    pwyw_tier.update!(customizable_price: true)
    membership.reload

    # The fixture must genuinely disagree with the (absent) line tier, or this example cannot
    # distinguish the scoped read from the product-wide one.
    expect(membership.has_customizable_price_option?).to be(true)

    cart = create(:cart)
    create(:cart_product, cart:, product: membership, option: nil, price: 0)

    expect(stripe_payment_props(cart:)).to eq(card_element_fallback("not_charged"))
  ensure
    Feature.deactivate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
  end

  # The same rule on the add_products path, whose payload records the selected tier as option_id.
  # A membership with no option_id must not consult the whole option list for the same reason, and
  # must not trust the product-level pwyw field either — that column can be stale-true on a
  # membership (see the buyer_can_name_price? comment).
  it "still falls back to CardElement when a membership is added with no tier selected" do
    seller = create(:user)
    Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
    membership = create(:membership_product, user: seller, price_cents: 0)
    membership.tiers.first.update_column(:customizable_price, false)
    pwyw_tier = create(:variant, variant_category: membership.tier_category, name: "Supporter")
    pwyw_tier.update!(customizable_price: true)
    membership.reload

    expect(membership.has_customizable_price_option?).to be(true)
    expect(membership.options.any? { _1[:is_pwyw] }).to be(true)

    expect(stripe_payment_props(add_products: [checkout_product_for(membership, price: 0, option_id: nil)]))
      .to eq(card_element_fallback("not_charged"))
  ensure
    Feature.deactivate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
  end

  # A cart mixing a free product with a pay-what-you-want one can still be paid, so the
  # presence of one free line must not drag the whole cart back to the legacy surface.
  it "keeps the Payment Element when a free line shares the cart with a pay-what-you-want line" do
    seller = create(:user)
    Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
    free_product = create(:product, user: seller, price_cents: 0)
    pwyw_product = create(:product, user: seller, price_cents: 0, customizable_price: true)

    expect(stripe_payment_props(add_products: [
                                  checkout_product_for(free_product, price: 0, pwyw: nil),
                                  checkout_product_for(pwyw_product, price: 0),
                                ]))
      .to eq(payment_element_props(stripe_elements_mode: described_class::STRIPE_ELEMENTS_MODE_FOR_PAYMENT_INTENT))
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

    it "keeps an installment cart on the server-confirm element even with both flags" do
      # A deferred ConfirmationToken cannot fund later off-session installments.
      expect(stripe_payment_props(add_products: [confirm_flagged_seller_product(pay_in_installments: true)]))
        .to eq(payment_element_props)
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

    # The same lane, for a cart whose listed amount is not yet known. A pay-what-you-want product
    # in a forced currency reads as zero at page load, and this surface mounts the Element with a
    # server-rendered presentment_amount_cents — so it would mount at 0. That number is not a
    # harmless placeholder: getStripePaymentElementAmount prefers it over checkout's own total for
    # the whole session (it returns presentment_amount_cents whenever it is non-null), so the
    # Element would still be at zero after the buyer named $25. Such a cart takes the canonical
    # server-confirm element instead, where the browser derives the amount from the loaded total.
    it "keeps a forced-currency pay-what-you-want cart off the method-forced element, which would mount at a zero listed amount" do
      seller, product = buyer_currency_seller_with_product(price_cents: 0)
      product.update!(customizable_price: true)
      activate_buyer_currency_flags(seller)
      allow(Stripe).to receive(:api_key).and_return("sk_test_currency")
      platform_merchant_account
      add_products = [
        checkout_product_for(
          product,
          price: 0,
          buyer_currency_display: { display_mode: "default", buyer_currency_shown: Currency::EUR }
        )
      ]

      # The premise: priced, this same cart really is the method-forced lane mounting a listed
      # EUR amount — so the zero case below is this lane declining a cart it would have taken.
      priced = stripe_payment_props(add_products: [checkout_product_for(product, price: 1500, buyer_currency_display: { display_mode: "default", buyer_currency_shown: Currency::EUR })])
      expect(priced[:integration]).to eq(described_class::STRIPE_PAYMENT_ELEMENT_CLIENT_CONFIRM_INTEGRATION)
      expect(priced[:elements_options][:presentment_amount_cents]).to eq(1500)

      props = stripe_payment_props(add_products:)

      expect(props[:integration]).to eq(described_class::STRIPE_PAYMENT_ELEMENT_INTEGRATION)
      expect(props[:fallback_reason]).to be_nil
      # The canonical element carries no server-rendered amount at all, so there is no zero for
      # the browser to prefer once the buyer names a price.
      expect(props[:elements_options]).not_to have_key(:presentment_amount_cents)
      expect(props[:elements_options][:currency]).to eq("usd")
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

    it "kicks a mixed candidate/installment cart to CardElement instead of client-confirm, which cannot charge an installment purchase" do
      # A mixed cart cannot be quoted, and installments keep method-forced client-confirm closed.
      seller, product = buyer_currency_seller_with_product(price_cents: 1500)
      installment_product = create(:product, user: seller, price_currency_type: "eur", price_cents: 3000)
      create(:product_installment_plan, link: installment_product)
      activate_buyer_currency_flags(seller)
      allow(Stripe).to receive(:api_key).and_return("sk_test_currency")
      platform_merchant_account
      add_products = [
        checkout_product_for(
          product,
          buyer_currency_display: {
            display_mode: "buyer_local",
            buyer_currency_shown: Currency::CAD,
          }
        ),
        checkout_product_for(
          installment_product,
          pay_in_installments: true,
          buyer_currency_display: {
            display_mode: "default",
            buyer_currency_shown: Currency::EUR,
          }
        )
      ]

      # disable_wallets: the fallback keeps the candidate cart's PRB suppression, matching the
      # buyer-currency element it would otherwise mount.
      expect(stripe_payment_props(add_products:))
        .to eq(card_element_fallback("buyer_currency_presentment_unsupported").merge(disable_wallets: true))
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

    it "mounts and displays a CAD listing in CAD for a Canadian card buyer in the direct-listed ramp" do
      seller, product = buyer_currency_seller_with_product(price_currency_type: Currency::CAD, price_cents: 1500)
      activate_buyer_currency_flags(seller)
      Feature.activate_user(Checkout::BuyerCurrencyEligibility::LISTED_CURRENCY_DIRECT_CHARGE_FEATURE_NAME, seller)
      allow(Stripe).to receive(:api_key).and_return("sk_live_currency")
      stub_geoip_country("24.48.0.1", "Canada")

      expect(stripe_payment_props(add_products: [checkout_product_for(product)], ip: "24.48.0.1")).to eq(
        payment_element_client_confirm_props(
          currency: Currency::CAD,
          presentment_amount_cents: 1500,
          direct_listed_card: true,
          disable_wallets: true,
        )
      )
    ensure
      if seller
        Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::LISTED_CURRENCY_DIRECT_CHARGE_FEATURE_NAME, seller)
        deactivate_buyer_currency_flags(seller)
      end
    end

    it "mounts a multi-item cart uniformly priced in CAD as one direct-listed CAD element" do
      seller, product = buyer_currency_seller_with_product(price_currency_type: Currency::CAD, price_cents: 1500)
      second_product = create(:product, user: seller, price_currency_type: Currency::CAD, price_cents: 2500)
      activate_buyer_currency_flags(seller)
      Feature.activate_user(Checkout::BuyerCurrencyEligibility::LISTED_CURRENCY_DIRECT_CHARGE_FEATURE_NAME, seller)
      allow(Stripe).to receive(:api_key).and_return("sk_live_currency")
      stub_geoip_country("24.48.0.1", "Canada")

      add_products = [checkout_product_for(product), checkout_product_for(second_product)]
      expect(stripe_payment_props(add_products:, ip: "24.48.0.1")).to eq(
        payment_element_client_confirm_props(
          currency: Currency::CAD,
          presentment_amount_cents: 4000,
          direct_listed_card: true,
          disable_wallets: true,
        )
      )
    ensure
      if seller
        Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::LISTED_CURRENCY_DIRECT_CHARGE_FEATURE_NAME, seller)
        deactivate_buyer_currency_flags(seller)
      end
    end

    it "keeps a cart mixing CAD and USD listings on the canonical USD element even in the direct-listed ramp" do
      seller, product = buyer_currency_seller_with_product(price_currency_type: Currency::CAD, price_cents: 1500)
      usd_product = create(:product, user: seller, price_currency_type: Currency::USD, price_cents: 2500)
      activate_buyer_currency_flags(seller)
      Feature.activate_user(Checkout::BuyerCurrencyEligibility::LISTED_CURRENCY_DIRECT_CHARGE_FEATURE_NAME, seller)
      allow(Stripe).to receive(:api_key).and_return("sk_live_currency")
      stub_geoip_country("24.48.0.1", "Canada")

      add_products = [checkout_product_for(product), checkout_product_for(usd_product)]
      expect(stripe_payment_props(add_products:, ip: "24.48.0.1"))
        .to eq(payment_element_client_confirm_props)
    ensure
      if seller
        Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::LISTED_CURRENCY_DIRECT_CHARGE_FEATURE_NAME, seller)
        deactivate_buyer_currency_flags(seller)
      end
    end

    it "keeps that CAD listing on the USD element while the direct-listed ramp is off" do
      seller, product = buyer_currency_seller_with_product(price_currency_type: Currency::CAD, price_cents: 1500)
      activate_buyer_currency_flags(seller)
      allow(Stripe).to receive(:api_key).and_return("sk_live_currency")
      stub_geoip_country("24.48.0.1", "Canada")

      expect(stripe_payment_props(add_products: [checkout_product_for(product)], ip: "24.48.0.1"))
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

    it "mounts card + UPI for the flagged single paid-upfront INR membership slice" do
      seller = create(:user, disable_buyer_local_currency: false)
      product = create(:membership_product, user: seller, price_currency_type: Currency::INR, price_cents: 73_000)
      # Deliberately no STRIPE_PAYMENT_ELEMENT_CHECKOUT flag: the UPI Autopay registration
      # shape must survive a base-flag ramp-down (CardElement cannot mount UPI), so this
      # example pins that the shape skips the flag-gated CardElement fallback.
      Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CLIENT_CONFIRM_FEATURE_NAME, seller)
      activate_buyer_currency_flags(seller)
      Feature.activate_user(Checkout::BuyerCurrencyEligibility::SUBSCRIPTION_FEATURE_NAME, seller)
      Feature.activate_user(:checkout_local_method_upi, seller)
      Feature.activate(Checkout::PaymentMethodResolver::UPI_RECURRING_SERVICING_FEATURE)
      Feature.activate_user(Checkout::PaymentMethodResolver::UPI_RECURRING_LAUNCH_FEATURE, seller)
      allow(Stripe).to receive(:api_key).and_return("sk_live_currency")
      stub_geoip_country("203.0.113.13", "India")

      props = stripe_payment_props(
        # Membership products keep their price on tiers, so pass the selected tier price just
        # as the real checkout payload does.
        add_products: [checkout_product_for(product, price: 73_000, recurrence: BasePrice::Recurrence::MONTHLY)],
        ip: "203.0.113.13"
      )

      expect(props).to eq(
        payment_element_client_confirm_props(
          currency: Currency::INR,
          presentment_amount_cents: 73_000,
          payment_method_types: %w[card upi],
          stripe_link_enabled: false,
          recurring_upi_registration: true,
          disable_wallets: true,
        )
      )
    ensure
      Feature.deactivate(Checkout::PaymentMethodResolver::UPI_RECURRING_SERVICING_FEATURE)
      if seller
        Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::SUBSCRIPTION_FEATURE_NAME, seller)
        Feature.deactivate_user(:checkout_local_method_upi, seller)
        Feature.deactivate_user(Checkout::PaymentMethodResolver::UPI_RECURRING_LAUNCH_FEATURE, seller)
        deactivate_buyer_currency_flags(seller)
      end
    end

    it "keeps the CardElement fallback for the UPI membership shape when its client-confirm lane cannot mount" do
      # The base-flag exemption above only applies to a cart that will actually take the UPI
      # client-confirm lane; with the client-confirm flag off, the shape falls back like any
      # other cart instead of mounting a Payment Element the seller's flags don't allow.
      seller = create(:user, disable_buyer_local_currency: false)
      product = create(:membership_product, user: seller, price_currency_type: Currency::INR, price_cents: 73_000)
      activate_buyer_currency_flags(seller)
      Feature.activate_user(Checkout::BuyerCurrencyEligibility::SUBSCRIPTION_FEATURE_NAME, seller)
      Feature.activate_user(:checkout_local_method_upi, seller)
      Feature.activate(Checkout::PaymentMethodResolver::UPI_RECURRING_SERVICING_FEATURE)
      Feature.activate_user(Checkout::PaymentMethodResolver::UPI_RECURRING_LAUNCH_FEATURE, seller)
      allow(Stripe).to receive(:api_key).and_return("sk_live_currency")
      stub_geoip_country("203.0.113.15", "India")

      props = stripe_payment_props(
        add_products: [checkout_product_for(product, price: 73_000, recurrence: BasePrice::Recurrence::MONTHLY)],
        ip: "203.0.113.15"
      )

      expect(props).to eq(card_element_fallback("stripe_payment_element_flag_disabled"))
    ensure
      Feature.deactivate(Checkout::PaymentMethodResolver::UPI_RECURRING_SERVICING_FEATURE)
      if seller
        Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::SUBSCRIPTION_FEATURE_NAME, seller)
        Feature.deactivate_user(:checkout_local_method_upi, seller)
        Feature.deactivate_user(Checkout::PaymentMethodResolver::UPI_RECURRING_LAUNCH_FEATURE, seller)
        deactivate_buyer_currency_flags(seller)
      end
    end

    it "keeps unsupported recurring shapes off the UPI Autopay registration lane" do
      seller = create(:user, disable_buyer_local_currency: false)
      product = create(:membership_product, user: seller, price_currency_type: Currency::INR, price_cents: 73_000)
      Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CLIENT_CONFIRM_FEATURE_NAME, seller)
      activate_buyer_currency_flags(seller)
      Feature.activate_user(Checkout::BuyerCurrencyEligibility::SUBSCRIPTION_FEATURE_NAME, seller)
      Feature.activate_user(:checkout_local_method_upi, seller)
      Feature.activate(Checkout::PaymentMethodResolver::UPI_RECURRING_SERVICING_FEATURE)
      Feature.activate_user(Checkout::PaymentMethodResolver::UPI_RECURRING_LAUNCH_FEATURE, seller)
      allow(Stripe).to receive(:api_key).and_return("sk_live_currency")
      stub_geoip_country("203.0.113.14", "India")

      item = checkout_product_for(product, price: 73_000, recurrence: BasePrice::Recurrence::MONTHLY)
      unsupported = {
        multi_item: [item.deep_dup, item.deep_dup],
        quantity: [item.deep_dup.tap { _1[:quantity] = 2 }],
        installment: [item.deep_dup.tap { _1[:pay_in_installments] = true }],
        offered_installment_plan: [item.deep_dup.tap { _1[:product][:installment_plan] = { number_of_installments: 2 } }],
        preorder: [item.deep_dup.tap { _1[:product][:is_preorder] = true }],
        free_trial: [item.deep_dup.tap { _1[:product][:free_trial] = { duration: { unit: "day", amount: 7 } } }],
        physical: [item.deep_dup.tap { _1[:product][:require_shipping] = true }],
        commission: [item.deep_dup.tap { _1[:product][:native_type] = Link::NATIVE_TYPE_COMMISSION }],
      }

      aggregate_failures do
        unsupported.each do |shape, add_products|
          props = stripe_payment_props(add_products:, ip: "203.0.113.14")

          expect(props[:integration]).not_to eq(described_class::STRIPE_PAYMENT_ELEMENT_CLIENT_CONFIRM_INTEGRATION), shape.to_s
          expect(Array(props.dig(:elements_options, :payment_method_types))).not_to include("upi"), shape.to_s
        end

        create(:merchant_account, user: seller)
        seller.merchant_accounts.reset
        props = stripe_payment_props(add_products: [item], ip: "203.0.113.14")
        expect(props[:integration]).not_to eq(described_class::STRIPE_PAYMENT_ELEMENT_CLIENT_CONFIRM_INTEGRATION), "seller_merchant_account"
        expect(Array(props.dig(:elements_options, :payment_method_types))).not_to include("upi"), "seller_merchant_account"
      end
    ensure
      Feature.deactivate(Checkout::PaymentMethodResolver::UPI_RECURRING_SERVICING_FEATURE)
      if seller
        Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::SUBSCRIPTION_FEATURE_NAME, seller)
        Feature.deactivate_user(:checkout_local_method_upi, seller)
        Feature.deactivate_user(Checkout::PaymentMethodResolver::UPI_RECURRING_LAUNCH_FEATURE, seller)
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

    it "mounts the buyer-currency element for a recurring EUR-priced presentment candidate instead of crashing" do
      # A recurring cart is rejected by the payment method resolver (client-confirm covers
      # one-time purchases and the UPI Autopay registration shape, which this EUR cart is
      # not), so its resolution carries a nil method list. The
      # method-forced shape check — evaluated before the presentment shape in the supported
      # check — must consult the resolver's eligibility verdict before scanning the method
      # list, or this cart raises instead of mounting the element.
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
        payment_element_props(buyer_currency_presentment: true, disable_wallets: true)
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
      # The wallet button renders on CardElement checkouts too (below-minimum carts and other
      # Payment Element fallbacks), so the flag must reach the frontend on every integration.
      seller = create(:user)
      product = create(:product, user: seller, price_cents: 1234)
      Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
      Feature.activate_user(described_class::APPLE_PAY_MERCHANT_TOKENS_FEATURE_NAME, seller)

      expect(stripe_payment_props(add_products: [checkout_product_for(product, price: described_class::STRIPE_PAYMENT_ELEMENT_MINIMUM_USD_CHARGE_CENTS - 1)]))
        .to eq(card_element_fallback("stripe_payment_element_amount_below_minimum", request_apple_pay_merchant_tokens: true))
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
      # CardElement carts (below-minimum carts and other fallbacks) never mount a Payment
      # Element, so there is no element wallet surface to enable — they keep the Payment
      # Request Button.
      seller = create(:user)
      product = create(:product, user: seller, price_cents: 1234)
      Feature.activate_user(described_class::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
      Feature.activate_user(described_class::PAYMENT_ELEMENT_WALLETS_FEATURE_NAME, seller)

      expect(stripe_payment_props(add_products: [checkout_product_for(product, price: described_class::STRIPE_PAYMENT_ELEMENT_MINIMUM_USD_CHARGE_CENTS - 1)]))
        .to eq(card_element_fallback("stripe_payment_element_amount_below_minimum"))
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
