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
    it "renders the product's custom HTML when present" do
      get :show, params: { id: product.unique_permalink }
      expect(response).to be_successful
      expect(response.body).to include("<h1>Live landing page</h1>")
    end

    it "sets the custom HTML CSP and iframe response headers" do
      get :show, params: { id: product.unique_permalink }
      expect(response.headers["Content-Security-Policy"]).to eq(CUSTOM_HTML_CSP)
      expect(response.headers["X-Frame-Options"]).to eq("SAMEORIGIN")
      expect(response.headers["Referrer-Policy"]).to eq("no-referrer")
    end

    it "does not set custom HTML headers when custom_html is blank" do
      product.update!(custom_html: nil)
      get :show, params: { id: product.unique_permalink }
      expect(response.body).not_to include("<h1>Live landing page</h1>")
      expect(response.headers["Content-Security-Policy"]).to be_nil
    end

    it "skips custom_html when ?wanted=true (checkout flow)" do
      get :show, params: { id: product.unique_permalink, wanted: "true" }
      # checkout flow redirects away; custom HTML must not render
      expect(response.body).not_to include("<h1>Live landing page</h1>")
    end
  end
end
