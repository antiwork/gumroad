# frozen_string_literal: true

require "spec_helper"

# Exercises the real routing constraints for first-class Pages: a seller's
# slugged pages serve at /<slug> on their username subdomain and custom
# domains — rich text pages as a direct server-rendered document, custom HTML
# pages through the same sandboxed wrapper + embed pipeline as the profile.
describe "Public serving of seller pages", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:seller) { create(:user, username: "pageseller", name: "Jane Doe") }
  let!(:custom_domain) { create(:custom_domain, user: seller, domain: "seller.example.com") }

  before do
    Feature.activate_user(:custom_html_pages, seller)
  end

  describe "rich text pages" do
    let!(:page) { create(:user_page, pageable: seller, slug: "about", title: "About", content: "<p>Hello there</p>") }

    it "renders the page at its slug on the subdomain" do
      get "http://#{seller.subdomain}/about"

      expect(response).to be_successful
      expect(response.body).to include("<p>Hello there</p>")
      expect(response.body).to include("<title>About — Jane Doe</title>")
    end

    it "renders the page at its slug on the custom domain" do
      get "http://seller.example.com/about"

      expect(response).to be_successful
      expect(response.body).to include("<p>Hello there</p>")
    end

    it "includes canonical and OG meta for the page" do
      get "http://#{seller.subdomain}/about"

      expect(response.body).to include(%(property="og:title" content="About"))
      expect(response.body).to include(%(rel="canonical"))
    end

    it "404s an unknown slug" do
      get "http://#{seller.subdomain}/nope"

      expect(response).to have_http_status(:not_found)
    end

    it "404s the landing embed for a rich text page" do
      get "http://#{seller.subdomain}/about/landing/embed"

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "custom HTML pages" do
    let!(:page) do
      create(:user_page, pageable: seller, slug: "studio", title: "Studio",
                         custom_html: "<section><h1>Studio landing</h1></section>")
    end

    it "renders the sandboxed wrapper at the slug, not the raw HTML" do
      get "http://#{seller.subdomain}/studio"

      expect(response).to be_successful
      expect(response.body).to include(%(src="/studio/landing/embed"))
      expect(response.body).not_to include("<h1>Studio landing</h1>")
    end

    it "serves the embed with the strict CSP" do
      get "http://#{seller.subdomain}/studio/landing/embed"

      expect(response).to be_successful
      expect(response.body).to include("<h1>Studio landing</h1>")
      expect(response.headers["Content-Security-Policy"]).to eq(RendersCustomHtmlPages::CUSTOM_HTML_CSP)
      expect(response.headers["X-Frame-Options"]).to eq("SAMEORIGIN")
    end

    it "injects the navigation bridge with the seller's store hostnames" do
      get "http://seller.example.com/studio/landing/embed"

      expect(response.body).to include("data-gumroad-navigation-bridge")
      expect(response.body).to include("seller.example.com")
    end

    it "reports the page version to the owner for live reload" do
      sign_in seller
      get "http://#{seller.subdomain}/studio/landing/version"

      expect(response).to be_successful
      expect(response.parsed_body).to eq("present" => true, "version" => page.reload.updated_at.to_i)
    end

    it "does not report the version to visitors" do
      get "http://#{seller.subdomain}/studio/landing/version"

      expect(response.parsed_body).to eq("present" => false, "version" => nil)
    end
  end

  describe "route precedence" do
    it "does not shadow existing storefront routes" do
      # /posts is a real route on the seller subdomain — the pages catch-all
      # must never intercept it.
      get "http://#{seller.subdomain}/posts"

      expect(response).to redirect_to("/")
    end

    it "still serves the profile at the root" do
      get "http://#{seller.subdomain}/"

      expect(response).to be_successful
    end
  end
end
