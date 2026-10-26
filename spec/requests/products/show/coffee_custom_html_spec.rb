# frozen_string_literal: true

require "spec_helper"

# /coffee is a coffee product's canonical URL (the product's short link redirects
# there), so a published custom landing page has to render on both surfaces, and the
# custom page's buy button — which arrives as /l/:permalink?wanted=true — must still
# reach the standard coffee page instead of bouncing back to the page it came from.
describe "Coffee product custom landing page", type: :request do
  let(:seller) { create(:user, :eligible_for_service_products) }
  let!(:coffee) do
    create(:product, user: seller, native_type: Link::NATIVE_TYPE_COFFEE,
                     custom_html: "<main><h1>Coffee landing</h1></main>")
  end

  before do
    Feature.activate_user(:custom_html_pages, seller)
    host! URI.parse(seller.subdomain_with_protocol).host
  end

  it "serves the custom landing page at /coffee" do
    get "/coffee"

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("gumroad-landing-frame")
    expect(response.body).to include(%(src="/l/#{coffee.unique_permalink}/landing/embed"))
  end

  it "serves the custom landing page at the short link" do
    get "/l/#{coffee.unique_permalink}"

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("gumroad-landing-frame")
  end

  it "serves the landing iframe the wrapper embeds" do
    get "/l/#{coffee.unique_permalink}/landing/embed"

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Coffee landing")
  end

  it "sends the custom page's buy button to the standard coffee page, not back to the custom page" do
    get "/l/#{coffee.unique_permalink}", params: { wanted: "true" }

    expect(response).to redirect_to("/coffee?wanted=true")

    follow_redirect!

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include("gumroad-landing-frame")
  end

  it "honours the ?native=true escape hatch from the short link" do
    get "/l/#{coffee.unique_permalink}", params: { native: "true" }
    follow_redirect!

    expect(response.body).not_to include("gumroad-landing-frame")
  end

  it "keeps serving the standard coffee page when the feature is off" do
    Feature.deactivate_user(:custom_html_pages, seller)

    get "/coffee"

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include("gumroad-landing-frame")
  end
end
