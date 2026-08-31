# frozen_string_literal: true

require "spec_helper"

# A single USD-priced client-confirm cart for an Indian buyer mounts in USD and carries the INR
# remount contract instead of listing UPI up front: Stripe rejects a UPI-listed USD session, so
# `inr_local_methods` names what the browser may add only after remounting in the quoted INR.
# These specs pin that contract through CheckoutController#show's checkout_payment Inertia prop —
# the payload the browser actually mounts from — rather than the presenter in isolation.
describe "checkout_payment INR/UPI remount contract", type: :request do
  let(:seller) { create(:user, disable_buyer_local_currency: false) }
  let!(:product) { create(:product, user: seller, price_cents: 1500) }

  before do
    allow_any_instance_of(ActionDispatch::Request).to receive(:host).and_return(VALID_REQUEST_HOSTS.first)
    allow(Stripe).to receive(:api_key).and_return("sk_live_currency")
    allow(GeoIp).to receive(:lookup).and_return(
      GeoIp::Result.new(
        country_name: "India", country_code: "IN", region_name: "MH",
        city_name: "Mumbai", postal_code: "400001", latitude: nil, longitude: nil
      )
    )
    Feature.activate_user(Checkout::StripePaymentPresenter::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
    Feature.activate_user(Checkout::StripePaymentPresenter::STRIPE_PAYMENT_ELEMENT_CLIENT_CONFIRM_FEATURE_NAME, seller)
    Feature.activate_user(:buyer_local_currency, seller)
    Feature.activate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)
    Feature.activate_user(:checkout_local_method_upi, seller)
  end

  after do
    Feature.deactivate_user(:checkout_local_method_upi, seller)
    Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)
    Feature.deactivate_user(:buyer_local_currency, seller)
    Feature.deactivate_user(Checkout::StripePaymentPresenter::STRIPE_PAYMENT_ELEMENT_CLIENT_CONFIRM_FEATURE_NAME, seller)
    Feature.deactivate_user(Checkout::StripePaymentPresenter::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, seller)
  end

  def checkout_payment_props
    get "/checkout", params: { product: product.unique_permalink }, headers: { "X-Inertia" => "true" }
    expect(response).to be_successful
    JSON.parse(response.body).dig("props", "checkout_payment")
  end

  it "advertises the INR remount with UPI on the initial USD client-confirm mount" do
    payment = checkout_payment_props

    expect(payment["integration"]).to eq(Checkout::StripePaymentPresenter::STRIPE_PAYMENT_ELEMENT_CLIENT_CONFIRM_INTEGRATION)
    elements_options = payment.fetch("elements_options")
    expect(elements_options["currency"]).to eq("usd")
    expect(elements_options["buyer_currency_presentment"]).to be(true)
    expect(elements_options["inr_local_methods"]).to include("upi")
    expect(elements_options["payment_method_types"]).not_to include("upi")
  end

  it "keeps an opted-out seller's checkout on the canonical USD contract" do
    seller.update!(disable_buyer_local_currency: true)

    elements_options = checkout_payment_props.fetch("elements_options")

    expect(elements_options["currency"]).to eq("usd")
    expect(elements_options["buyer_currency_presentment"]).to be(false)
    expect(elements_options["inr_local_methods"]).to eq([])
    expect(elements_options["payment_method_types"]).not_to include("upi")
  end
end
