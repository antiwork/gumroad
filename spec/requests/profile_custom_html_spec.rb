# frozen_string_literal: true

require "spec_helper"

# Exercises the real routing constraints (controller specs bypass them) to
# confirm a profile's custom HTML renders, and the embed gets the strict CSP,
# on a seller's own custom domain — the watch-out flagged in the issue.
describe "Profile custom HTML rendering", type: :request do
  include Devise::Test::IntegrationHelpers

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

  describe "navigation bridge" do
    it "injects the click-interception script into the embed with the seller's store hostnames" do
      get "http://seller.example.com/landing/embed"

      expect(response.body).to include("data-gumroad-navigation-bridge")
      expect(response.body).to include("gumroad:navigate")
      expect(response.body).to include("seller.example.com")
      # The seller's canonical subdomain is allowlisted too: product URLs in
      # the injected gumroad-data JSON are built on the subdomain even when
      # the visitor browses the custom domain.
      expect(response.body).to include(URI(seller.subdomain_with_protocol).host)
    end

    it "installs the validating gumroad:navigate listener in the trusted wrapper" do
      get "http://seller.example.com/"

      expect(response.body).to include("gumroad:navigate")
      expect(response.body).to include("STORE_HOSTNAMES")
      expect(response.body).to include("seller.example.com")
      expect(response.body).to include(URI(seller.subdomain_with_protocol).host)
    end

    it "never allowlists a shared Gumroad host — only hosts the seller controls" do
      # Viewed via a shared root-domain route (gumroad.com/:username), the
      # request host is NOT the seller's own; allowlisting it would let the
      # seller's sandboxed HTML navigate the visitor's tab to arbitrary
      # gumroad.com paths. The allowlist must contain only the seller's
      # subdomain and custom domain.
      get "http://#{VALID_REQUEST_HOSTS.last}/#{seller.username}/landing/embed"

      expect(response).to be_successful
      expect(response.body).to include(URI(seller.subdomain_with_protocol).host)
      expect(response.body).to include("seller.example.com")
      VALID_REQUEST_HOSTS.each do |shared_host|
        expect(response.body).not_to include("\"#{shared_host}\"")
      end
    end

    it "keeps the iframe sandbox unchanged — still no allow-same-origin or allow-top-navigation" do
      get "http://seller.example.com/"

      expect(response.body).to include(%(sandbox="allow-scripts allow-forms allow-popups allow-popups-to-escape-sandbox"))
      expect(response.body).not_to include("allow-same-origin")
      expect(response.body).not_to include("allow-top-navigation")
    end
  end

  describe "follow bridge" do
    it "injects the serve-time form-interception helper into the embed" do
      get "http://seller.example.com/landing/embed"

      expect(response.body).to include("data-gumroad-follow-bridge")
      expect(response.body).to include("gumroad:follow")
    end

    it "installs the validating gumroad:follow listener in the trusted wrapper, with the seller id baked in from the wrapper's own context" do
      get "http://seller.example.com/"

      expect(response.body).to include("data-gumroad-follow-wrapper")
      expect(response.body).to include(seller.external_id)
      expect(response.body).to include("/follow_from_embed_form")
      # The wrapper carries a csrf-token meta tag (via CsrfTokenInjector) so
      # the follow fetch keeps the visitor's session — that's what lets a
      # signed-in visitor following with their own verified email skip the
      # confirmation-email round trip.
      expect(response.body).to include(%(name="csrf-token"))
    end

    # The wrapper fetches the follow endpoint relative to its own host — the
    # seller's custom domain or subdomain — which routes through
    # UserCustomDomainConstraint, not the apex-host block where the canonical
    # route lives. Without the custom-domain route the bridge would 404. The
    # body is form-encoded like the bridge sends it: the Rack::Attack
    # per-(IP, seller) throttle reads req.params, which never parses JSON.
    it "accepts the follow POST on the custom domain the wrapper is served from" do
      post "http://seller.example.com/follow_from_embed_form",
           params: { seller_id: seller.external_id, email: "fan@example.com" },
           headers: { "Accept" => "application/json" }

      expect(response).to be_successful
      expect(response.parsed_body["success"]).to be(true)
      follower = Follower.last
      expect(follower.user).to eq(seller)
      expect(follower.email).to eq("fan@example.com")
      expect(follower.source).to eq(Follower::From::EMBED_FORM)
    end

    it "accepts the follow POST on the seller's subdomain" do
      post "http://#{URI(seller.subdomain_with_protocol).host}/follow_from_embed_form",
           params: { seller_id: seller.external_id, email: "fan@example.com" },
           headers: { "Accept" => "application/json" }

      expect(response).to be_successful
      expect(response.parsed_body["success"]).to be(true)
    end

    it "does not route a .json-suffixed path — that path variant would bypass the path-matched Rack::Attack throttles" do
      post "http://seller.example.com/follow_from_embed_form.json",
           params: { seller_id: seller.external_id, email: "fan@example.com" }

      expect(response).to have_http_status(:not_found)
      expect(Follower.count).to eq(0)
    end
  end

  describe "owner live-reload poll" do
    it "injects the version poll into the wrapper only for the signed-in owner" do
      sign_in seller
      get "http://seller.example.com/"

      expect(response.body).to include("/landing/version")
      expect(response.body).to include("gumroad-landing-frame")
    end

    it "omits the poll for anonymous visitors" do
      get "http://seller.example.com/"

      expect(response.body).not_to include("/landing/version")
    end

    it "omits the poll for a signed-in visitor who is not the owner" do
      sign_in create(:user)
      get "http://seller.example.com/"

      expect(response.body).not_to include("/landing/version")
    end
  end

  describe "injected catalog data" do
    it "embeds the seller's public products as JSON so the page can render them dynamically" do
      create(:product, user: seller, name: "Cool thing")

      get "http://seller.example.com/landing/embed"

      expect(response.body).to include(%(id="gumroad-data"))
      json = response.body[%r{<script id="gumroad-data"[^>]*>(.*?)</script>}m, 1]
      data = JSON.parse(json)
      expect(data.keys).to match_array(%w[products posts pages])
      expect(data["products"].map { _1["name"] }).to include("Cool thing")
      expect(data["products"].first.keys).to match_array(%w[name url price native_type thumbnail_url description])
    end
  end

  describe "preview field sync" do
    it "includes the name/bio live-update listener on the owner's ?preview embed" do
      sign_in seller
      get "http://seller.example.com/landing/embed?preview=true"
      expect(response.body).to include("gumroad:profile-fields")
    end

    it "omits the listener on a ?preview embed for anyone other than the owner" do
      get "http://seller.example.com/landing/embed?preview=true"
      expect(response.body).not_to include("gumroad:profile-fields")
    end

    it "omits the listener on the public embed" do
      get "http://seller.example.com/landing/embed"
      expect(response.body).not_to include("gumroad:profile-fields")
    end
  end

  describe "version endpoint" do
    before { sign_in seller }

    it "reports the live page with a version token to the owner" do
      get "http://seller.example.com/landing/version"

      expect(response).to be_successful
      body = response.parsed_body
      expect(body["present"]).to be(true)
      expect(body["version"]).to be_a(Integer)
    end

    it "reports present:false once the page is cleared, so a watching owner restores the default profile" do
      seller.update!(custom_html: "")

      get "http://seller.example.com/landing/version"

      expect(response).to be_successful
      expect(response.parsed_body["present"]).to be(false)
    end

    it "reports present:false when the feature is disabled" do
      Feature.deactivate_user(:custom_html_pages, seller)

      get "http://seller.example.com/landing/version"

      expect(response.parsed_body["present"]).to be(false)
    end

    it "reports present:false to a non-owner, never leaking the edit timestamp" do
      sign_out seller

      get "http://seller.example.com/landing/version"

      expect(response.parsed_body["present"]).to be(false)
      expect(response.parsed_body["version"]).to be_nil
    end
  end
end
