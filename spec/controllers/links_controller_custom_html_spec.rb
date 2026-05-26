# frozen_string_literal: true

require "spec_helper"

describe LinksController, :vcr, type: :controller do
  CUSTOM_HTML_CSP = "default-src 'none'; script-src 'unsafe-inline' https://cdn.tailwindcss.com https://cdn.jsdelivr.net https://unpkg.com; style-src 'unsafe-inline' https://cdn.tailwindcss.com https://fonts.googleapis.com https://fonts.bunny.net; img-src * data:; font-src * data:; connect-src 'none'; form-action 'self';"

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
      expect(response.body).to include(%(src="/l/#{product.unique_permalink}/landing/embed"))
      expect(response.body).not_to include("<h1>Live landing page</h1>")
    end

    it "sandboxes the iframe without top-navigation and mediates checkout via postMessage" do
      get :show, params: { id: product.unique_permalink }
      expect(response.body).to include(%(sandbox="allow-scripts allow-forms"))
      expect(response.body).not_to include("allow-top-navigation")
      # The wrapper owns the one checkout URL it will navigate to; seller HTML
      # only sends the "gumroad:checkout" signal.
      expect(response.body).to include(%(window.location.href = "/l/#{product.unique_permalink}?wanted=true"))
      expect(response.body).to include('e.data === "gumroad:checkout"')
      # Script carries a nonce — script-src has no 'unsafe-inline', so without
      # it the listener would be CSP-blocked in the browser.
      expect(response.body).to match(/<script nonce="[^"]+">/)
      # Only our own iframe can trigger checkout — gate on e.source so an
      # embedding page can't drive the navigation.
      expect(response.body).to include("e.source === frame.contentWindow")
    end

    it "falls back to the default product page when custom_html is blank" do
      product.update!(custom_html: nil)
      get :show, params: { id: product.unique_permalink }
      expect(response.body).not_to include("<h1>Live landing page</h1>")
      expect(response.body).not_to include(%(src="/l/#{product.unique_permalink}/landing/embed"))
    end

    it "skips the wrapper when ?wanted=true and lets the checkout redirect fire" do
      get :show, params: { id: product.unique_permalink, wanted: "true" }
      expect(response).to be_redirect
      expect(response.location).to include("/checkout")
      expect(response.body).not_to include(%(src="/l/#{product.unique_permalink}/landing/embed"))
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
      expect(response.headers["Content-Type"]).to include("text/html")
      expect(response.headers["Content-Type"]).to include("charset=utf-8")
    end

    it "404s when the product has no custom_html" do
      product.update!(custom_html: nil)
      get :landing_iframe_content, params: { id: product.unique_permalink }
      expect(response).to have_http_status(:not_found)
    end

    it "interpolates data-gumroad-field markers with live product values" do
      product.update!(custom_html: %(<h1 data-gumroad-field="name">placeholder</h1><a data-gumroad-action="buy" href="#">Buy</a>))

      get :landing_iframe_content, params: { id: product.unique_permalink }

      expect(response.body).to include(">#{product.name}<")
      expect(response.body).not_to include(">placeholder<")
      expect(response.body).to include(%(href="/l/#{product.unique_permalink}?wanted=true"))
    end
  end

  describe "PUT update (internal dashboard, session-authed Reset flow)" do
    before { sign_in seller }

    it "clears the landing page via the Reset button (custom_html: null)" do
      expect(product.reload.custom_html).to be_present

      put :update, params: { id: product.unique_permalink, custom_html: nil }

      expect(response).to be_successful
      expect(product.reload.custom_html).to be_nil
    end

    it "sanitizes seller-supplied custom_html on the internal update path" do
      put :update, params: { id: product.unique_permalink, custom_html: %(<section><script src="https://evil.com/x.js"></script><h1>Hi</h1></section>) }

      expect(response).to be_successful
      stored = product.reload.custom_html
      expect(stored).to include("<h1>Hi</h1>")
      expect(stored).not_to include("evil.com")
    end
  end
end
