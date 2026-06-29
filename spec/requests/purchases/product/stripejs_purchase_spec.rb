# frozen_string_literal: true

require("spec_helper")
require "timeout"

describe("PurchaseScenario using StripeJs", type: :system, js: true) do
  def checkout_payment_props
    page.evaluate_script(<<~JS)
      JSON.parse(document.querySelector("[data-page]").getAttribute("data-page")).props.checkout.checkout_payment
    JS
  end

  it "uses a users saved cc if they have one" do
    previous_successful_sales_count = Purchase.successful.count
    link = create(:product, price_cents: 200)
    user = create(:user)
    credit_card = create(:credit_card)
    credit_card.users << user
    login_as user
    visit "#{link.user.subdomain_with_protocol}/l/#{link.unique_permalink}"
    add_to_cart(link)
    check_out(link, logged_in_user: user)
    expect(Purchase.successful.count).to eq previous_successful_sales_count + 1
  end

  it("allows the buyer to pay with a new credit card") do
    link = create(:product_with_pdf_file, user: create(:user))

    visit("/l/#{link.unique_permalink}")

    expect(Stripe::PaymentMethod).to receive(:retrieve).and_call_original
    expect(Stripe::PaymentIntent).to receive(:create).and_call_original

    add_to_cart(link)
    check_out(link)

    new_purchase = Purchase.last
    expect(new_purchase.stripe_transaction_id).to match(/\Ach_/)
    expect(new_purchase.stripe_fingerprint).to_not be(nil)
    expect(new_purchase.card_type).to eq "visa"
    expect(new_purchase.card_country).to eq "US"
    expect(new_purchase.card_country_source).to eq Purchase::CardCountrySource::STRIPE
    expect(new_purchase.card_visual).to eq "**** **** **** 4242"
    expect(new_purchase.card_expiry_month).to eq StripePaymentMethodHelper::EXPIRY_MM.to_i
    expect(new_purchase.card_expiry_year).to eq StripePaymentMethodHelper::EXPIRY_YYYY.to_i
    expect(new_purchase.successful?).to be(true)
  end

  it "allows the buyer to pay with a new credit card using the Payment Element" do
    seller = create(:user)
    MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id) ||
      create(:merchant_account, user: nil, charge_processor_merchant_id: "acct_#{SecureRandom.hex(8)}")
    product = create(:product_with_pdf_file, user: seller)
    Feature.activate_user(Checkout::StripePaymentPresenter::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, product.user)

    visit("/checkout?product=#{product.unique_permalink}")

    # The Payment Element tokenizes the typed-in card into a connected-account payment method that can't be charged
    # against the platform in test mode, so we swap it for a known platform payment method while recording the real
    # id the frontend produced. The card-detail assertions below therefore reflect platform_payment_method.
    platform_payment_method = StripePaymentMethodHelper.success.with_zip_code("94107").to_stripejs_payment_method
    payment_element_payment_method_ids = []
    allow(StripeChargeablePaymentMethod).to receive(:new).and_wrap_original do |original, payment_method_id, *args, **kwargs|
      payment_element_payment_method_ids << payment_method_id
      original.call(platform_payment_method.id, *args, **kwargs)
    end
    expect(Stripe::PaymentMethod).to receive(:retrieve).with(platform_payment_method.id).and_call_original
    expect(Stripe::PaymentIntent).to receive(:create).and_call_original

    checkout_payment = checkout_payment_props
    expect(checkout_payment["integration"]).to eq("payment_element")
    expect(checkout_payment["fallback_reason"]).to be_nil

    check_out(product, payment_element: true)

    new_purchase = Purchase.last
    expect(new_purchase.stripe_transaction_id).to match(/\Ach_/)
    expect(new_purchase.stripe_fingerprint).to_not be(nil)
    expect(new_purchase.card_type).to eq "visa"
    expect(new_purchase.card_country).to eq "US"
    expect(new_purchase.card_country_source).to eq Purchase::CardCountrySource::STRIPE
    expect(new_purchase.card_visual).to eq "**** **** **** 4242"
    expect(new_purchase.card_expiry_month).to eq platform_payment_method.card.exp_month
    expect(new_purchase.card_expiry_year).to eq platform_payment_method.card.exp_year
    expect(new_purchase.successful?).to be(true)
    expect(payment_element_payment_method_ids).to all(match(/\Apm_/))
    expect(payment_element_payment_method_ids).not_to be_empty
  end

  it "allows the buyer to pay for a mixed free and paid cart using the Payment Element" do
    seller = create(:user)
    MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id) ||
      create(:merchant_account, user: nil, charge_processor_merchant_id: "acct_#{SecureRandom.hex(8)}")
    paid_product_price_cents = CURRENCY_CHOICES[Currency::USD][:min_price]
    free_product = create(:product_with_pdf_file, user: seller, name: "Free bonus", price_cents: 0)
    paid_product = create(:product_with_pdf_file, user: seller, name: "Paid guide", price_cents: paid_product_price_cents)
    Feature.activate_user(Checkout::StripePaymentPresenter::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
    cart = create(:cart, :guest)
    create(:cart_product, cart:, product: free_product, price: 0)
    create(:cart_product, cart:, product: paid_product, price: paid_product_price_cents)

    visit checkout_path(cart_id: cart.secure_external_id(scope: "cart_login"))

    expect(page).to have_current_path(checkout_path)
    expect(page).to have_text("Free bonus")
    expect(page).to have_text("Paid guide")
    expect(page).to have_text("Total US$0.99", normalize_ws: true)
    checkout_payment = checkout_payment_props
    expect(checkout_payment["integration"]).to eq("payment_element")
    expect(checkout_payment["fallback_reason"]).to be_nil

    platform_payment_method = StripePaymentMethodHelper.success.with_zip_code("94107").to_stripejs_payment_method
    payment_element_payment_method_ids = []
    allow(StripeChargeablePaymentMethod).to receive(:new).and_wrap_original do |original, payment_method_id, *args, **kwargs|
      payment_element_payment_method_ids << payment_method_id
      original.call(platform_payment_method.id, *args, **kwargs)
    end
    expect(Stripe::PaymentMethod).to receive(:retrieve).with(platform_payment_method.id).and_call_original
    expect(Stripe::PaymentIntent).to receive(:create).and_call_original

    expect do
      check_out(paid_product, payment_element: true)
    end.to change { free_product.sales.successful.count }.by(1)

    paid_purchase = paid_product.sales.successful.last
    free_purchase = free_product.sales.successful.last
    expect(paid_purchase.price_cents).to eq(paid_product_price_cents)
    expect(paid_purchase.successful?).to be(true)
    expect(free_purchase.price_cents).to eq(0)
    expect(free_purchase.successful?).to be(true)
    expect(payment_element_payment_method_ids).to all(match(/\Apm_/))
    expect(payment_element_payment_method_ids).not_to be_empty
  end

  it "allows the buyer to pay for a checkout below Gumroad's minimum but chargeable by Stripe using the Payment Element" do
    seller = create(:user)
    MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id) ||
      create(:merchant_account, user: nil, charge_processor_merchant_id: "acct_#{SecureRandom.hex(8)}")
    near_zero_price_cents = Checkout::StripePaymentPresenter::STRIPE_PAYMENT_ELEMENT_MINIMUM_USD_CHARGE_CENTS + 10
    product = create(:product_with_pdf_file, user: seller, name: "Near-zero guide")
    # Product creation enforces Gumroad's minimum; this synthetic checkout verifies Stripe's lower charge floor.
    product.default_price.update_column(:price_cents, near_zero_price_cents)
    product.reload
    Feature.activate_user(Checkout::StripePaymentPresenter::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)

    visit("/checkout?product=#{product.unique_permalink}")

    expect(page).to have_current_path(checkout_path)
    expect(page).to have_text("Near-zero guide")
    expect(page).to have_text("Total US$0.60", normalize_ws: true)
    checkout_payment = checkout_payment_props
    expect(checkout_payment["integration"]).to eq("payment_element")
    expect(checkout_payment["fallback_reason"]).to be_nil

    platform_payment_method = StripePaymentMethodHelper.success.with_zip_code("94107").to_stripejs_payment_method
    payment_element_payment_method_ids = []
    allow(StripeChargeablePaymentMethod).to receive(:new).and_wrap_original do |original, payment_method_id, *args, **kwargs|
      payment_element_payment_method_ids << payment_method_id
      original.call(platform_payment_method.id, *args, **kwargs)
    end
    expect(Stripe::PaymentMethod).to receive(:retrieve).with(platform_payment_method.id).and_call_original
    expect(Stripe::PaymentIntent).to receive(:create).and_call_original

    expect do
      check_out(product, payment_element: true)
    end.to change { product.sales.successful.count }.by(1)

    purchase = product.sales.successful.last
    expect(purchase.price_cents).to eq(near_zero_price_cents)
    expect(purchase.successful?).to be(true)
    expect(payment_element_payment_method_ids).to all(match(/\Apm_/))
    expect(payment_element_payment_method_ids).not_to be_empty
  end

  it "renders Payment Element for a checkout total below Gumroad's minimum but chargeable by Stripe" do
    seller = create(:user)
    gumroad_minimum_amount_cents = CURRENCY_CHOICES[Currency::USD][:min_price]
    product = create(:product_with_pdf_file, user: seller, name: "Near-zero guide", customizable_price: true, price_cents: 0)
    Feature.activate_user(Checkout::StripePaymentPresenter::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
    cart = create(:cart, :guest)
    create(:cart_product, cart:, product:, price: gumroad_minimum_amount_cents - 1)

    visit checkout_path(cart_id: cart.secure_external_id(scope: "cart_login"))

    expect(page).to have_current_path(checkout_path)
    expect(page).to have_text("Near-zero guide")
    expect(page).to have_text("Total US$0.98", normalize_ws: true)
    checkout_payment = checkout_payment_props
    expect(checkout_payment["integration"]).to eq("payment_element")
    expect(checkout_payment["fallback_reason"]).to be_nil
    expect(page).to have_selector("iframe[src*='elements-inner-payment']")
  end

  it "renders CardElement fallback for a positive checkout total below the Payment Element minimum" do
    seller = create(:user)
    payment_element_minimum_amount_cents = Checkout::StripePaymentPresenter::STRIPE_PAYMENT_ELEMENT_MINIMUM_USD_CHARGE_CENTS
    product = create(:product_with_pdf_file, user: seller, name: "Near-zero guide", customizable_price: true, price_cents: 0)
    Feature.activate_user(Checkout::StripePaymentPresenter::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
    cart = create(:cart, :guest)
    create(:cart_product, cart:, product:, price: payment_element_minimum_amount_cents - 1)

    visit checkout_path(cart_id: cart.secure_external_id(scope: "cart_login"))

    expect(page).to have_current_path(checkout_path)
    expect(page).to have_text("Near-zero guide")
    expect(page).to have_text("Total US$0.49", normalize_ws: true)
    checkout_payment = checkout_payment_props
    expect(checkout_payment["integration"]).to eq("card_element")
    expect(checkout_payment["fallback_reason"]).to eq("stripe_payment_element_amount_below_minimum")
    expect(page).to have_selector(:fieldset, "Card information")
    expect(page).not_to have_selector("iframe[src*='elements-inner-payment']", wait: 0)
  end

  it "allows the buyer to pay for a recurring membership using the Payment Element reusable setup path" do
    seller = create(:user)
    MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id) ||
      create(:merchant_account, user: nil, charge_processor_merchant_id: "acct_#{SecureRandom.hex(8)}")
    product = create(:membership_product_with_preset_tiered_pricing, user: seller)
    Feature.activate_user(Checkout::StripePaymentPresenter::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, product.user)

    tier = product.variant_categories.alive.first.variants.alive.find_by!(name: "First Tier")

    visit("/checkout?product=#{product.unique_permalink}&option=#{tier.external_id}")

    platform_payment_method = StripePaymentMethodHelper.success.with_zip_code("94107").to_stripejs_payment_method
    payment_element_payment_method_ids = []
    allow(StripeChargeablePaymentMethod).to receive(:new).and_wrap_original do |original, payment_method_id, *args, **kwargs|
      payment_element_payment_method_ids << payment_method_id
      original.call(platform_payment_method.id, *args, **kwargs)
    end

    setup_intent_ids = []
    allow(ChargeProcessor).to receive(:setup_future_charges!).and_wrap_original do |original, *args, **kwargs|
      setup_intent = original.call(*args, **kwargs)
      setup_intent_ids << setup_intent.id if setup_intent.present?
      setup_intent
    end

    checkout_payment = checkout_payment_props
    expect(checkout_payment["integration"]).to eq("payment_element")
    expect(checkout_payment["fallback_reason"]).to be_nil

    check_out(product, payment_element: true)

    purchase = Purchase.last
    expect(purchase.successful?).to be(true)
    expect(purchase.subscription).to be_alive
    expect(purchase.credit_card).to be_present
    expect(purchase.credit_card.stripe_customer_id).to be_present
    expect(setup_intent_ids).to all(match(/\Aseti_/))
    expect(setup_intent_ids).not_to be_empty
    expect(payment_element_payment_method_ids).to all(match(/\Apm_/))
    expect(payment_element_payment_method_ids).not_to be_empty
  end

  it "lets a buyer with a saved card pay with it while the Payment Element is enabled" do
    seller = create(:user)
    MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id) ||
      create(:merchant_account, user: nil, charge_processor_merchant_id: "acct_#{SecureRandom.hex(8)}")
    product = create(:product_with_pdf_file, user: seller)
    Feature.activate_user(Checkout::StripePaymentPresenter::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)

    buyer = create(:user)
    saved_card = create(:credit_card)
    saved_card.users << buyer
    login_as(buyer)

    visit("/checkout?product=#{product.unique_permalink}")

    checkout_payment = page.evaluate_script(<<~JS)
      JSON.parse(document.querySelector("[data-page]").getAttribute("data-page")).props.checkout.checkout_payment
    JS
    expect(checkout_payment["integration"]).to eq("payment_element")
    expect(checkout_payment["fallback_reason"]).to be_nil

    expect(page).to have_selector("[aria-label='Saved credit card']", text: saved_card.visual)

    check_out(product, logged_in_user: buyer)

    new_purchase = Purchase.last
    expect(new_purchase.successful?).to be(true)
    expect(new_purchase.card_visual).to eq(saved_card.visual)
  end

  it "lets a buyer with a saved card enter a new card via the Payment Element" do
    seller = create(:user)
    MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id) ||
      create(:merchant_account, user: nil, charge_processor_merchant_id: "acct_#{SecureRandom.hex(8)}")
    product = create(:product_with_pdf_file, user: seller)
    Feature.activate_user(Checkout::StripePaymentPresenter::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)

    buyer = create(:user)
    saved_card = create(:credit_card)
    saved_card.users << buyer
    login_as(buyer)

    visit("/checkout?product=#{product.unique_permalink}")

    expect(page).to have_selector("[aria-label='Saved credit card']", text: saved_card.visual)

    platform_payment_method = StripePaymentMethodHelper.success.with_zip_code("94107").to_stripejs_payment_method
    payment_element_payment_method_ids = []
    allow(StripeChargeablePaymentMethod).to receive(:new).and_wrap_original do |original, payment_method_id, *args, **kwargs|
      payment_element_payment_method_ids << payment_method_id
      original.call(platform_payment_method.id, *args, **kwargs)
    end
    expect(Stripe::PaymentMethod).to receive(:retrieve).with(platform_payment_method.id).and_call_original
    expect(Stripe::PaymentIntent).to receive(:create).and_call_original

    check_out(product, logged_in_user: buyer) do
      click_on "Use a different card?"
      fill_in_payment_element
    end

    new_purchase = Purchase.last
    expect(new_purchase.successful?).to be(true)
    expect(payment_element_payment_method_ids).to all(match(/\Apm_/))
    expect(payment_element_payment_method_ids).not_to be_empty
  end

  it "charges every seller in a multi-seller cart with one card collected through the Payment Element" do
    buyer = create(:user)
    seller_1 = create(:user)
    seller_2 = create(:user)
    MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id) ||
      create(:merchant_account, user: nil, charge_processor_merchant_id: "acct_#{SecureRandom.hex(8)}")
    product_1 = create(:product, user: seller_1, price_cents: 1000)
    product_2 = create(:product, user: seller_2, price_cents: 1500)
    [seller_1, seller_2].each do |seller|
      Feature.activate_user(Checkout::StripePaymentPresenter::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
    end

    login_as buyer
    visit(product_1.long_url)
    add_to_cart(product_1)
    visit(product_2.long_url)
    add_to_cart(product_2)

    # A multi-seller cart is charged once per seller, so the Payment Element card must be collected as a reusable
    # payment method. The Payment Element tokenizes into a connected-account payment method that can't be charged
    # against the platform in test mode, so swap it for a known platform payment method while recording the real id.
    platform_payment_method = StripePaymentMethodHelper.success.with_zip_code("94107").to_stripejs_payment_method
    payment_element_payment_method_ids = []
    allow(StripeChargeablePaymentMethod).to receive(:new).and_wrap_original do |original, payment_method_id, *args, **kwargs|
      payment_element_payment_method_ids << payment_method_id
      original.call(platform_payment_method.id, *args, **kwargs)
    end

    setup_intent_ids = []
    allow(ChargeProcessor).to receive(:setup_future_charges!).and_wrap_original do |original, *args, **kwargs|
      setup_intent = original.call(*args, **kwargs)
      setup_intent_ids << setup_intent.id if setup_intent.present?
      setup_intent
    end

    checkout_payment = page.evaluate_script(<<~JS)
      JSON.parse(document.querySelector("[data-page]").getAttribute("data-page")).props.checkout.checkout_payment
    JS
    expect(checkout_payment["integration"]).to eq("payment_element")
    expect(checkout_payment["fallback_reason"]).to be_nil

    expect do
      fill_checkout_form(product_1, logged_in_user: buyer, payment_element: true)
      click_on "Pay", exact: true
      expect(page).to have_alert(text: "Your purchase was successful!", wait: 60)
    end.to change { Purchase.successful.count }.by(2)

    purchase_1 = product_1.sales.successful.sole
    purchase_2 = product_2.sales.successful.sole
    expect(purchase_1.seller).to eq(seller_1)
    expect(purchase_2.seller).to eq(seller_2)

    # One reusable card, collected once through the Payment Element, drives the charge for each seller (asserted
    # via the shared Payment Element payment method id below; each seller's charge gets its own CreditCard record).
    expect(purchase_1.credit_card.stripe_customer_id).to be_present
    expect(purchase_2.credit_card.stripe_customer_id).to be_present
    expect(setup_intent_ids).to all(match(/\Aseti_/))
    expect(setup_intent_ids).not_to be_empty
    expect(payment_element_payment_method_ids).to all(match(/\Apm_/))
    expect(payment_element_payment_method_ids.uniq.size).to eq(1)
  end

  it "allows the buyer to authorize a preorder using the Payment Element SetupIntent mode" do
    seller = create(:user)
    MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id) ||
      create(:merchant_account, user: nil, charge_processor_merchant_id: "acct_#{SecureRandom.hex(8)}")
    product = create(:product_with_pdf_file, user: seller, is_in_preorder_state: true)
    create(:preorder_link, link: product, release_at: 25.hours.from_now)
    Feature.activate_user(Checkout::StripePaymentPresenter::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, product.user)

    visit("/checkout?product=#{product.unique_permalink}")

    # See the one-off Payment Element spec above: use the frontend-created Payment Method only to prove the
    # Payment Element path ran, then swap in a known platform Payment Method for the backend Stripe call.
    platform_payment_method = StripePaymentMethodHelper.success.with_zip_code("94107").to_stripejs_payment_method
    payment_element_payment_method_ids = []
    allow(StripeChargeablePaymentMethod).to receive(:new).and_wrap_original do |original, payment_method_id, *args, **kwargs|
      payment_element_payment_method_ids << payment_method_id
      original.call(platform_payment_method.id, *args, **kwargs)
    end
    expect(Stripe::PaymentMethod).to receive(:retrieve).with(platform_payment_method.id).and_call_original
    expect(Stripe::SetupIntent).to receive(:create).and_call_original

    checkout_payment = page.evaluate_script(<<~JS)
      JSON.parse(document.querySelector("[data-page]").getAttribute("data-page")).props.checkout.checkout_payment
    JS
    expect(checkout_payment["integration"]).to eq("payment_element")
    expect(checkout_payment["fallback_reason"]).to be_nil
    expect(checkout_payment.dig("elements_options", "stripe_elements_mode")).to eq("setup")
    expect(checkout_payment.dig("elements_options", "payment_method_creation")).to eq("manual")

    check_out(product, payment_element: true)

    new_purchase = Purchase.last
    expect(new_purchase.preorder_authorization_successful?).to be(true)
    expect(new_purchase.stripe_transaction_id).not_to be_present
    expect(new_purchase.processor_setup_intent_id).to be_present
    expect(new_purchase.charge.stripe_setup_intent_id).to eq(new_purchase.processor_setup_intent_id)
    expect(payment_element_payment_method_ids).to all(match(/\Apm_/))
    expect(payment_element_payment_method_ids).not_to be_empty
  end

  it "allows the buyer to start a free-trial membership using the Payment Element SetupIntent mode" do
    seller = create(:user)
    MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id) ||
      create(:merchant_account, user: nil, charge_processor_merchant_id: "acct_#{SecureRandom.hex(8)}")
    product = create(
      :membership_product_with_preset_tiered_pricing,
      user: seller,
      unique_permalink: "spefuturechargesetup#{SecureRandom.alphanumeric(12, chars: ("a".."z").to_a)}",
      free_trial_enabled: true,
      free_trial_duration_amount: 1,
      free_trial_duration_unit: :week
    )
    tier = product.tiers.find_by!(name: "First Tier")
    Feature.activate_user(Checkout::StripePaymentPresenter::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, product.user)

    visit("/checkout?product=#{product.unique_permalink}&option=#{Rack::Utils.escape(tier.external_id)}")
    within_cart_item(product.name) do
      expect(page).to have_text("Tier: #{tier.name}")
    end
    expect(page).to have_text("one week free")
    expect(page).to have_text("$3 monthly after")
    expect(page).to have_text("Total US$0", normalize_ws: true)

    # See the one-off Payment Element spec above: use the frontend-created Payment Method only to prove the
    # Payment Element path ran, then swap in a known platform Payment Method for the backend Stripe call.
    platform_payment_method = StripePaymentMethodHelper.success.with_zip_code("94107").to_stripejs_payment_method
    payment_element_payment_method_ids = []
    allow(StripeChargeablePaymentMethod).to receive(:new).and_wrap_original do |original, payment_method_id, *args, **kwargs|
      payment_element_payment_method_ids << payment_method_id
      original.call(platform_payment_method.id, *args, **kwargs)
    end
    expect(Stripe::PaymentMethod).to receive(:retrieve).with(platform_payment_method.id).and_call_original
    expect(Stripe::SetupIntent).to receive(:create).and_call_original

    checkout_payment = page.evaluate_script(<<~JS)
      JSON.parse(document.querySelector("[data-page]").getAttribute("data-page")).props.checkout.checkout_payment
    JS
    expect(checkout_payment["integration"]).to eq("payment_element")
    expect(checkout_payment["fallback_reason"]).to be_nil
    expect(checkout_payment.dig("elements_options", "stripe_elements_mode")).to eq("setup")
    expect(checkout_payment.dig("elements_options", "payment_method_creation")).to eq("manual")

    check_out(product, payment_element: true)

    original_purchase = Purchase.last
    expect(original_purchase.not_charged?).to be(true)
    expect(original_purchase.stripe_transaction_id).not_to be_present
    expect(original_purchase.processor_setup_intent_id).to be_present
    expect(original_purchase.subscription).to be_alive
    expect(original_purchase.subscription.credit_card).to eq(original_purchase.credit_card)
    expect(payment_element_payment_method_ids).to all(match(/\Apm_/))
    expect(payment_element_payment_method_ids).not_to be_empty

    travel_to(original_purchase.subscription.free_trial_ends_at + 1.day) do
      expect do
        original_purchase.subscription.charge!
      end.to change { product.sales.successful.count }.by(1)
    end
  end

  describe "save credit card payment" do
    before :each do
      @buyer = create(:user)
      login_as(@buyer)
      @product = create(:product)
    end

    it "saves when opted" do
      visit "#{@product.user.subdomain_with_protocol}/l/#{@product.unique_permalink}"

      add_to_cart(@product)

      expect(page).to have_checked_field("Save card")

      check_out(@product, logged_in_user: @buyer)

      purchase = Purchase.last
      expect(purchase.purchase_state).to eq("successful")
      expect(purchase.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
      expect(purchase.card_type).to eq "visa"
      expect(purchase.card_country).to eq "US"
      expect(purchase.card_country_source).to eq Purchase::CardCountrySource::STRIPE
      expect(purchase.card_visual).to eq "**** **** **** 4242"

      credit_card = @buyer.reload.credit_card
      expect(CreditCard.last).to eq(credit_card)
      expect(credit_card.card_type).to eq(CardType::VISA)
      expect(credit_card.visual).to eq("**** **** **** 4242")
    end

    it "does not save the card when opted out" do
      visit "#{@product.user.subdomain_with_protocol}/l/#{@product.unique_permalink}"
      add_to_cart(@product)
      expect(page).to have_checked_field("Save card")
      uncheck "Save card"
      check_out(@product, logged_in_user: @buyer)

      purchase = Purchase.last
      expect(purchase.card_type).to eq "visa"
      expect(purchase.card_country).to eq "US"
      expect(purchase.card_country_source).to eq Purchase::CardCountrySource::STRIPE
      expect(purchase.card_visual).to eq "**** **** **** 4242"

      expect(@buyer.reload.credit_card).to be(nil)
    end
  end

  describe "pay what you want" do
    before do
      @pwyw_product = create(:product)
    end

    describe "paid, untaxed purchase without shipping" do
      before do
        @pwyw_product.price_range = "30+"
        @pwyw_product.customizable_price = true
        @pwyw_product.save!
      end

      it "shows the payment blurb" do
        visit "/l/#{@pwyw_product.unique_permalink}"

        add_to_cart(@pwyw_product, pwyw_price: 35)

        expect(page).to have_text("Total US$35", normalize_ws: true)
      end
    end

    describe "multiple variants: 0+ and non-0+" do
      before do
        @pwyw_product.price_range = "0+"
        @pwyw_product.customizable_price = true
        @pwyw_product.save!

        @variant_category = create(:variant_category, link: @pwyw_product, title: "type")
        @var_zero_plus = create(:variant, variant_category: @variant_category, name: "Zero-plus", price_difference_cents: 0)
        @var_paid = create(:variant, variant_category: @variant_category, name: "Paid", price_difference_cents: 500)
      end

      it "lets to purchase the zero-plus variant for free" do
        visit "/l/#{@pwyw_product.unique_permalink}"

        add_to_cart(@pwyw_product, pwyw_price: 0, option: "Zero-plus")

        check_out(@pwyw_product, is_free: true)
      end

      it "does not let to purchase the paid variant for free, shows PWYW error instead of going to CC form" do
        visit "/l/#{@pwyw_product.unique_permalink}"

        choose "Paid"
        fill_in "Name a fair price", with: 0
        click_on "I want this!"
        expect(find_field("Name a fair price")["aria-invalid"]).to eq("true")
        expect(page).not_to have_button("Pay")

        fill_in "Name a fair price", with: 4
        click_on "I want this!"
        expect(find_field("Name a fair price")["aria-invalid"]).to eq("true")
        expect(page).not_to have_button("Pay")

        add_to_cart(@pwyw_product, pwyw_price: 6, option: "Paid")

        expect(page).to have_button("Pay")

        expect(page).to have_text("Total US$6", normalize_ws: true)

        check_out(@pwyw_product)

        purchase = Purchase.last
        expect(purchase.card_type).to eq "visa"
        expect(purchase.card_country).to eq "US"
        expect(purchase.card_country_source).to eq Purchase::CardCountrySource::STRIPE
        expect(purchase.card_visual).to eq "**** **** **** 4242"
        expect(purchase.price_cents).to eq(6_00)
      end
    end

    describe "free purchase" do
      before do
        @pwyw_product.price_range = "0+"
        @pwyw_product.customizable_price = true
        @pwyw_product.save!
      end

      it "does not show the payment blurb nor 'charged your card' message" do
        visit "/l/#{@pwyw_product.unique_permalink}"

        add_to_cart(@pwyw_product, pwyw_price: 0)

        check_out(@pwyw_product, is_free: true)
      end

      describe "processes an EU style formatted PWYW input" do
        it "parses and charges the right amount" do
          visit "/l/#{@pwyw_product.unique_permalink}"

          add_to_cart(@pwyw_product, pwyw_price: 1000.50)

          expect(page).to have_text("Total US$1,000.50", normalize_ws: true)

          check_out(@pwyw_product, is_free: false)

          purchase = Purchase.last
          expect(purchase.card_type).to eq "visa"
          expect(purchase.card_country).to eq "US"
          expect(purchase.card_country_source).to eq Purchase::CardCountrySource::STRIPE
          expect(purchase.card_visual).to eq "**** **** **** 4242"
          expect(purchase.price_cents).to eq(100050)
        end
      end
    end
  end
end
