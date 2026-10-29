# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe SellerPlanController, type: :controller do
  let(:seller) { create(:named_seller) }
  let(:product) { create(:product, user: seller, draft: true) }
  let!(:offer) { SellerPlanOffer.record_offer!(user: seller, link: product, arm: "ten", price_cents: 1000) }

  before do
    Rails.application.routes_reloader.execute_unless_loaded
    allow(GlobalConfig).to receive(:get).and_call_original
    allow(GlobalConfig).to receive(:get).with("SELLER_PLAN_PRICE_10").and_return("price_ten")
    sign_in seller
  end

  it "sends the seller to Stripe Checkout and records the attempt" do
    session = double(id: "cs_test_123", url: "https://checkout.stripe.com/c/pay/cs_test_123")
    expect(Stripe::Checkout::Session).to receive(:create)
      .with(hash_including(mode: "subscription", customer_email: seller.email))
      .and_return(session)

    get :checkout

    expect(response).to redirect_to("https://checkout.stripe.com/c/pay/cs_test_123")
    expect(offer.reload).to have_attributes(status: "checkout_started", stripe_checkout_session_id: "cs_test_123")
  end

  it "sends a seller with no offer back to the dashboard" do
    offer.destroy!

    get :checkout

    expect(response).to redirect_to(root_path)
  end
end
