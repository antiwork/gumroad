# frozen_string_literal: true

require "spec_helper"

# End-to-end coverage for the recurring UPI Autopay Payment Element cart (gp#2190 / PR #7481).
#
# The tipped-mount fix in payment.ts is exercised by unit specs; what only a real browser can
# answer is whether the tipped scenario is REACHABLE: the checkout presenter serves
# has_tipping_enabled=false for every recurring product, so the tip selector must not render on
# this cart at all. The control example proves the same seller's one-time INR product does offer
# the selector, so an absence here is the recurring gate and not a broken fixture.
describe "Recurring UPI Autopay checkout", type: :system, js: true do
  def checkout_payment_props
    page.evaluate_script(<<~JS)
      JSON.parse(document.querySelector("[data-page]").getAttribute("data-page")).props.checkout_payment
    JS
  end

  let(:india) do
    GeoIp::Result.new(
      country_name: "India", country_code: "IN", region_name: "KA",
      city_name: "Bengaluru", postal_code: "560001", latitude: nil, longitude: nil
    )
  end

  before do
    allow(GeoIp).to receive(:lookup).and_return(india)
    @seller = create(:user_with_compliance_info, disable_buyer_local_currency: false, tipping_enabled: true)
    Feature.activate_user(Checkout::StripePaymentPresenter::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, @seller)
    Feature.activate_user(Checkout::StripePaymentPresenter::STRIPE_PAYMENT_ELEMENT_CLIENT_CONFIRM_FEATURE_NAME, @seller)
    Feature.activate_user(:buyer_local_currency, @seller)
    Feature.activate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, @seller)
    Feature.activate_user(Checkout::BuyerCurrencyEligibility::SUBSCRIPTION_FEATURE_NAME, @seller)
    Feature.activate_user(:checkout_local_method_upi, @seller)
    Feature.activate(Checkout::PaymentMethodResolver::UPI_RECURRING_SERVICING_FEATURE)
    Feature.activate_user(Checkout::PaymentMethodResolver::UPI_RECURRING_LAUNCH_FEATURE, @seller)
    MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id) ||
      create(:merchant_account, user: nil, charge_processor_merchant_id: "acct_#{SecureRandom.hex(8)}")
    @membership = create(
      :membership_product_with_preset_tiered_pricing,
      user: @seller,
      price_currency_type: Currency::INR,
      price_cents: 73_000,
      recurrence_price_values: [
        { "monthly": { enabled: true, price: 730 } },
        { "monthly": { enabled: true, price: 990 } },
      ]
    )
  end

  after do
    Feature.deactivate(Checkout::PaymentMethodResolver::UPI_RECURRING_SERVICING_FEATURE)
    Feature.deactivate_user(Checkout::PaymentMethodResolver::UPI_RECURRING_LAUNCH_FEATURE, @seller)
    Feature.deactivate_user(:checkout_local_method_upi, @seller)
    Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::SUBSCRIPTION_FEATURE_NAME, @seller)
    Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, @seller)
    Feature.deactivate_user(:buyer_local_currency, @seller)
    Feature.deactivate_user(Checkout::StripePaymentPresenter::STRIPE_PAYMENT_ELEMENT_CLIENT_CONFIRM_FEATURE_NAME, @seller)
    Feature.deactivate_user(Checkout::StripePaymentPresenter::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, @seller)
  end

  it "mounts the recurring UPI registration element and does not offer the tip selector" do
    visit "/l/#{@membership.unique_permalink}"
    add_to_cart(@membership, option: "First Tier")

    checkout_payment = checkout_payment_props
    expect(checkout_payment["integration"]).to eq("payment_element_client_confirm")
    expect(checkout_payment["fallback_reason"]).to be_nil
    expect(checkout_payment["recurring_upi_registration"]).to be(true)
    expect(checkout_payment.dig("elements_options", "currency")).to eq("inr")
    expect(checkout_payment.dig("elements_options", "presentment_amount_cents")).to eq(73_000)
    expect(checkout_payment.dig("elements_options", "payment_method_types")).to include("upi")

    expect(page).to have_selector("iframe[src*='elements-inner-payment']", wait: 20)
    expect(page).to have_text("₹730")

    # The presenter serves has_tipping_enabled=false for recurring products, so the tipped
    # Element amount the unit specs pin cannot currently be produced through the UI.
    expect(page).to have_no_text("Add a tip?")
  end

  it "offers the tip selector for the same seller's one-time INR product (control)" do
    product = create(:product_with_pdf_file, user: @seller, price_currency_type: Currency::INR, price_cents: 73_000)

    visit "/l/#{product.unique_permalink}"
    add_to_cart(product)

    expect(page).to have_selector("iframe[src*='elements-inner-payment']", wait: 20)
    expect(page).to have_text("Add a tip?")
  end
end
