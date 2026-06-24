# frozen_string_literal: true

require "spec_helper"

# Exercises the real routing constraints (controller specs bypass them) to
# confirm a profile's custom HTML renders, and the embed gets the strict CSP,
# on a seller's own custom domain — the watch-out flagged in the issue.
describe "Profile custom HTML rendering", type: :request do
  let(:seller) { create(:user, username: "customprofile", name: "Jane Doe") }
  let!(:custom_domain) { create(:custom_domain, user: seller, domain: "seller.example.com") }

  before do
    seller.update!(custom_html: "<section><h1>Profile landing</h1></section>")
    Feature.activate_user(:custom_html_pages, seller)
  end

  it "renders the sandboxed wrapper on the custom-domain profile root" do
    get "http://seller.example.com/"

    expect(response).to be_successful
    expect(response.body).to include(%(src="/landing/embed"))
    expect(response.body).not_to include("<h1>Profile landing</h1>")
  end

  it "renders the wrapper for Accept: */* clients (crawlers/unfurlers), not just text/html" do
    get "http://seller.example.com/", headers: { "Accept" => "*/*" }

    expect(response).to be_successful
    expect(response.body).to include(%(src="/landing/embed"))
  end

  it "serves the embed with the strict CSP on the custom domain" do
    get "http://seller.example.com/landing/embed"

    expect(response).to be_successful
    expect(response.body).to include("<h1>Profile landing</h1>")
    expect(response.headers["Content-Security-Policy"]).to eq(RendersCustomHtmlPages::CUSTOM_HTML_CSP)
    expect(response.headers["X-Frame-Options"]).to eq("SAMEORIGIN")
  end

  it "404s the embed on the custom domain when the feature is disabled" do
    Feature.deactivate_user(:custom_html_pages, seller)

    get "http://seller.example.com/landing/embed"

    expect(response).to have_http_status(:not_found)
  end

  it "does not expose a checkout bridge on the profile embed" do
    get "http://seller.example.com/landing/embed"

    expect(response.body).not_to include("gumroad:checkout")
    expect(response.body).not_to include("wanted=true")
  end
end
