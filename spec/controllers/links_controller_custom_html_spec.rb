# frozen_string_literal: true

require "spec_helper"

describe LinksController, :vcr, type: :controller do
  CUSTOM_HTML_CSP = "default-src 'none'; script-src 'unsafe-inline' https://cdn.tailwindcss.com https://cdn.jsdelivr.net https://unpkg.com; style-src 'unsafe-inline' https://cdn.tailwindcss.com; img-src * data:; font-src * data:; connect-src 'none'; form-action 'self';"

  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller, custom_html: "<section><h1>Live landing page</h1></section>") }

  before do
    @request.host = URI.parse(seller.subdomain_with_protocol).host
  end

  describe "GET show with custom_html" do
    it "renders a wrapper page with an iframe pointing at the landing endpoint" do
      get :show, params: { id: product.unique_permalink }
      expect(response).to be_successful
      expect(response.body).to include("<title>#{product.name}</title>")
      expect(response.body).to include(%(property="og:title"))
      expect(response.body).to include(%(src="/l/#{product.unique_permalink}/landing"))
      expect(response.body).to include("allow-top-navigation-by-user-activation")
      expect(response.body).not_to include("<h1>Live landing page</h1>")
    end

    it "falls back to the default product page when custom_html is blank" do
      product.update!(custom_html: nil)
      get :show, params: { id: product.unique_permalink }
      expect(response.body).not_to include("<h1>Live landing page</h1>")
      expect(response.body).not_to include(%(src="/l/#{product.unique_permalink}/landing"))
    end

    it "skips the wrapper when ?wanted=true (checkout flow)" do
      get :show, params: { id: product.unique_permalink, wanted: "true" }
      expect(response.body).not_to include(%(src="/l/#{product.unique_permalink}/landing"))
    end
  end

  describe "GET landing_iframe_content" do
    it "renders the seller's HTML inside a chromeless document" do
      get :landing_iframe_content, params: { id: product.unique_permalink }
      expect(response).to be_successful
      expect(response.body).to include("<h1>Live landing page</h1>")
      expect(response.body).to start_with("<!doctype html>")
    end

    it "applies the strict CSP and iframe-friendly response headers" do
      get :landing_iframe_content, params: { id: product.unique_permalink }
      expect(response.headers["Content-Security-Policy"]).to eq(CUSTOM_HTML_CSP)
      expect(response.headers["X-Frame-Options"]).to eq("SAMEORIGIN")
      expect(response.headers["Referrer-Policy"]).to eq("no-referrer")
    end

    it "404s when the product has no custom_html" do
      product.update!(custom_html: nil)
      get :landing_iframe_content, params: { id: product.unique_permalink }
      expect(response).to have_http_status(:not_found)
    end
  end
end
