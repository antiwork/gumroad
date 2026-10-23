# frozen_string_literal: true

require "spec_helper"

# Exercises the real routing constraints for first-class Pages: a seller's
# slugged pages serve at /<slug> on their username subdomain and custom
# domains — rich text pages as a direct server-rendered document, custom HTML
# pages through the same sandboxed wrapper + embed pipeline as the profile.
describe "Public serving of seller pages", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:seller) { create(:user, username: "pageseller", name: "Jane Doe") }
  let!(:custom_domain) { create(:custom_domain, :verified_with_certificate, user: seller, domain: "seller.example.com") }

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

    it "does not repeat the store name when the page title already ends with it" do
      page.update!(title: "About | Jane Doe")

      get "http://#{seller.subdomain}/about"

      expect(response.body).to include("<title>About | Jane Doe</title>")
    end

    it "includes canonical and OG meta for the page" do
      get "http://#{seller.subdomain}/about"

      expect(response.body).to include(%(property="og:title" content="About"))
      expect(response.body).to include(%(rel="canonical"))
      expect(response.body).not_to include(%(name="description"))
    end

    it "uses the seller's SEO title and description" do
      page.update!(seo_title: "About Jane's studio", seo_description: "Hand-lettered posters & prints.")

      get "http://#{seller.subdomain}/about"

      expect(response.body).to include("<title>About Jane&#39;s studio</title>")
      expect(response.body).to include(%(property="og:title" content="About Jane&#39;s studio"))
      expect(response.body).to include(%(name="description" content="Hand-lettered posters &amp; prints."))
      expect(response.body).to include(%(property="og:description" content="Hand-lettered posters &amp; prints."))
      expect(response.body).to include(%(<h1 class="page-title">About</h1>))
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

    it "titles the wrapper document for the browser tab and search results" do
      get "http://seller.example.com/studio"

      expect(response.body).to include("<title>Studio — Jane Doe</title>")
    end

    it "does not repeat the store name when the page title already ends with it" do
      page.update!(title: "Free Art Teacher Vault | Jane Doe")

      get "http://seller.example.com/studio"

      expect(response.body).to include("<title>Free Art Teacher Vault | Jane Doe</title>")
    end

    it "puts the seller's SEO title and description on the wrapper document" do
      page.update!(seo_title: "Studio sessions", seo_description: "Book a studio session.")

      get "http://seller.example.com/studio"

      expect(response.body).to include("<title>Studio sessions</title>")
      expect(response.body).to include(%(property="og:title" content="Studio sessions"))
      expect(response.body).to include(%(name="description" content="Book a studio session."))
      expect(response.body).to include(%(property="og:description" content="Book a studio session."))
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

    # Slugged pages share the profile's follow bridge: helper in the sandboxed
    # embed, validating listener (with the seller id from the wrapper's own
    # render context) in the trusted wrapper.
    it "injects the follow bridge into the embed and the validating listener into the wrapper" do
      get "http://seller.example.com/studio/landing/embed"
      expect(response.body).to include("data-gumroad-follow-bridge")

      get "http://seller.example.com/studio"
      expect(response.body).to include("data-gumroad-follow-wrapper")
      expect(response.body).to include(seller.external_id)
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

  describe "share card meta tags" do
    let!(:page) do
      create(:user_page, pageable: seller, slug: "vault", title: "Free Art Teacher Vault",
                         custom_html: "<section><h1>Vault</h1></section>")
    end

    def attach_subscribe_preview(user)
      user.subscribe_preview.attach(
        io: File.open(Rails.root.join("spec", "support", "fixtures", "subscribe_preview.png")),
        filename: "subscribe_preview.png",
        content_type: "image/png"
      )
    end

    def attach_avatar(user)
      user.avatar.attach(
        io: File.open(Rails.root.join("spec", "support", "fixtures", "smilie.png")),
        filename: "smilie.png",
        content_type: "image/png"
      )
    end

    it "serves the seller's subscribe-preview card on og:image and twitter:image" do
      attach_subscribe_preview(seller)

      get "http://seller.example.com/vault"

      expect(seller.subscribe_preview_url).to be_present
      expect(response.body).to include(%(<meta property="og:image" content="#{ERB::Util.h(seller.subscribe_preview_url)}">))
      expect(response.body).to include(%(<meta property="og:image:alt" content="Jane Doe">))
      expect(response.body).to include(%(<meta property="og:image:type" content="image/png">))
      expect(response.body).to include(%(<meta property="og:image:width" content="#{SubscribePreviewGeneratorService::OUTPUT_WIDTH}">))
      expect(response.body).to include(%(<meta property="og:image:height" content="#{SubscribePreviewGeneratorService::OUTPUT_HEIGHT}">))
      expect(response.body).to include(%(<meta property="twitter:card" content="summary_large_image">))
      expect(response.body).to include(%(<meta property="twitter:image" content="#{ERB::Util.h(seller.subscribe_preview_url)}">))
    end

    # Both page variants build their head through UserPagesController#page_meta_head.
    it "serves the same card on a rich text page" do
      create(:user_page, pageable: seller, slug: "about", title: "About", content: "<p>Hi</p>")
      attach_subscribe_preview(seller)

      get "http://#{seller.subdomain}/about"

      expect(response.body).to include(%(<meta property="og:image" content="#{ERB::Util.h(seller.subscribe_preview_url)}">))
    end

    it "falls back to an uploaded avatar with no twitter card" do
      attach_avatar(seller)

      get "http://seller.example.com/vault"

      expect(seller.subscribe_preview_url).to be_nil
      expect(response.body).to include(%(<meta property="og:image" content="#{ERB::Util.h(seller.avatar_url)}">))
      expect(response.body).to include(%(<meta property="og:image:alt" content="Jane Doe's profile picture">))
      expect(response.body).not_to include(%(property="twitter:image"))
      expect(response.body).not_to include(%(property="twitter:card"))
      expect(response.body).not_to include(%(property="og:image:width"))
    end

    # With neither asset, omitting the tag lets scrapers use their own fallback
    # rather than advertising Gumroad's generic banner as this seller's card.
    it "omits og:image when the seller has neither a preview nor an avatar" do
      get "http://seller.example.com/vault"

      expect(response.body).not_to include(%(<meta property="og:image"))
      expect(response.body).not_to include("opengraph_image")
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
