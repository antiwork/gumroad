# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe SellerPlanController, type: :controller do
  let(:seller) { create(:named_seller) }
  let(:product) { create(:product, user: seller, draft: true) }
  let!(:offer) { SellerPlanOffer.record_offer!(user: seller, product: product, arm: "ten", price_cents: 1000) }

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

  it "does not open a second checkout for a seller who already pays" do
    offer.update!(status: "active", stripe_subscription_id: "sub_123")
    expect(Stripe::Checkout::Session).not_to receive(:create)

    get :checkout

    expect(response).to redirect_to(edit_link_path(product.unique_permalink))
    expect(offer.reload.status).to eq("active")
  end

  it "reuses a still-open checkout session instead of creating another" do
    offer.update!(status: "checkout_started", stripe_checkout_session_id: "cs_open")
    allow(Stripe::Checkout::Session).to receive(:retrieve).with("cs_open")
      .and_return(double(status: "open", url: "https://checkout.stripe.com/c/pay/cs_open"))
    expect(Stripe::Checkout::Session).not_to receive(:create)

    get :checkout

    expect(response).to redirect_to("https://checkout.stripe.com/c/pay/cs_open")
  end

  it "starts the plan for the selected seller when a team admin asks" do
    admin = create(:user)
    create(:team_membership, user: admin, seller:, role: TeamMembership::ROLE_ADMIN)
    sign_out seller
    sign_in admin
    cookies.encrypted[:current_seller_id] = seller.id
    session = double(id: "cs_team", url: "https://checkout.stripe.com/c/pay/cs_team")
    expect(Stripe::Checkout::Session).to receive(:create).and_return(session)

    get :checkout

    expect(response).to redirect_to("https://checkout.stripe.com/c/pay/cs_team")
    expect(offer.reload.stripe_checkout_session_id).to eq("cs_team")
  end

  it "tells the seller to retry when Stripe is unreachable" do
    allow(Stripe::Checkout::Session).to receive(:create).and_raise(Stripe::APIConnectionError.new("down"))

    get :checkout

    expect(response).to redirect_to(edit_link_url(product.unique_permalink))
    expect(flash[:alert]).to include("publish again to retry")
  end

  it "says the plan is already active when it activates mid-request" do
    allow(SellerPlan::Checkout).to receive(:new).and_raise(SellerPlan::Checkout::AlreadyActive)

    get :checkout

    expect(response).to redirect_to(edit_link_path(product.unique_permalink))
    expect(flash[:notice]).to include("already active")
  end

  it "keeps publishing free and points to support when the plan price is missing" do
    allow(SellerPlan::Checkout).to receive(:new).and_raise(SellerPlan::Checkout::PriceMissing)

    get :checkout

    expect(response).to redirect_to(root_path)
    expect(flash[:alert]).to include("still free today")
  end

  it "points the seller to support on an unexpected failure" do
    allow(Stripe::Checkout::Session).to receive(:create).and_raise(StandardError, "boom")

    get :checkout

    expect(response).to redirect_to(root_path)
    expect(flash[:alert]).to include("support@gumroad.com")
  end
end
