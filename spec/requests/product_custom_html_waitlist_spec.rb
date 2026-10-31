# frozen_string_literal: true

require "spec_helper"

describe "product custom HTML waitlist bridge", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:seller) { create(:user, username: "waitlistseller") }
  let(:form_html) { %(<form data-gumroad-waitlist><input type="email" name="email"><p data-gumroad-waitlist-message></p></form>) }
  let!(:product) { create(:product, user: seller, custom_html: form_html, waitlist_enabled: true, purchase_disabled_at: Time.current) }
  let(:base) { "http://#{seller.subdomain}/l/#{product.unique_permalink}" }

  before do
    Feature.activate_user(:custom_html_pages, seller)
    allow_any_instance_of(ActionView::Base).to receive(:vite_typescript_tag).and_return("")
  end

  it "serves the custom page to a visitor with the wrapper listener bound to this product" do
    get base

    expect(response).to be_successful
    expect(response.body).to include("data-gumroad-waitlist-wrapper")
    expect(response.body).to include(product.external_id)
    expect(response.body).to include(seller.external_id)
  end

  it "injects the bridge into the embed and leaves data-gumroad-launched off" do
    get "#{base}/landing/embed"

    expect(response).to be_successful
    expect(response.body).to include("data-gumroad-waitlist-bridge")
    expect(response.body).to include("gumroad:waitlist:result")
    expect(response.body).not_to include("data-gumroad-launched")
  end

  it "does not serve the embed to a visitor once the waitlist is off" do
    product.update!(waitlist_enabled: false)

    get "#{base}/landing/embed"
    expect(response).to have_http_status(:not_found)
  end

  it "does not show a staff-unpublished product" do
    product.update!(is_unpublished_by_admin: true)

    get "#{base}/landing/embed"

    expect(response).to have_http_status(:not_found)
  end

  it "marks a launched product and carries no waitlist bridge" do
    product.update!(purchase_disabled_at: nil, draft: false, waitlist_enabled: true)

    get "#{base}/landing/embed"

    expect(response).to be_successful
    expect(response.body).to include("data-gumroad-launched")
    expect(response.body).not_to include("data-gumroad-waitlist-bridge")
  end

  it "accepts the waitlist signup POST on a product-owned domain" do
    seller.update!(user_risk_state: "compliant")
    create(:custom_domain, user: nil, product:, domain: "waitlist-product.example.com")

    expect do
      post "http://waitlist-product.example.com/follow_from_embed_form",
           params: { seller_id: seller.external_id, product_id: product.external_id, email: "fan@example.com" },
           headers: { "Accept" => "application/json" }
    end.to change { WaitlistEntry.count }.by(1)

    expect(response.parsed_body["success"]).to be(true)
  end
end
