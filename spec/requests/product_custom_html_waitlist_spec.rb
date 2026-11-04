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

  it "serves a custom page whose own script posts gumroad:waitlist without a waitlist form" do
    product.update!(custom_html: %(<input id="email"><button id="join">Join</button><script>document.getElementById("join").onclick = function () { window.parent.postMessage({ type: "gumroad:waitlist", email: document.getElementById("email").value, requestId: "1" }, "*"); };</script>))

    get base

    expect(response).to be_successful
    expect(response.body).to include("data-gumroad-waitlist-wrapper")

    get "#{base}/landing/embed"
    expect(response).to be_successful
  end

  it "keeps the native waitlist page when the custom page has no waitlist form or hook" do
    product.update!(custom_html: %(<h1>Coming soon</h1>))

    get base, headers: { "X-Inertia" => "true" }

    expect(response).to be_successful
    expect(response.body).not_to include("data-gumroad-waitlist-wrapper")
    expect(JSON.parse(response.body).dig("props", "product", "waitlist")).to be_present

    get "#{base}/landing/embed"
    expect(response).to have_http_status(:not_found)
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

  it "marks a launched product and leaves out the waitlist listener and bridge" do
    product.update!(purchase_disabled_at: nil, draft: false, waitlist_enabled: true)

    get base

    expect(response.body).to include(%(src="/l/#{product.unique_permalink}/landing/embed"))
    expect(response.body).not_to include("data-gumroad-waitlist-wrapper")

    get "#{base}/landing/embed"

    expect(response).to be_successful
    expect(response.body).to include("data-gumroad-launched")
    expect(response.body).not_to include("data-gumroad-waitlist-bridge")
  end

  it "does not mark an unpublished product without a waitlist as launched in the seller's preview" do
    product.update!(waitlist_enabled: false)
    sign_in seller

    get "#{base}/landing/embed"

    expect(response).to be_successful
    expect(response.body).not_to include("data-gumroad-launched")
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
    entry = WaitlistEntry.last
    expect(entry.product).to eq(product)
    expect(entry.follower.source).to eq(Follower::From::EMBED_FORM)
  end
end
