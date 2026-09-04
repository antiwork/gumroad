# frozen_string_literal: true

require "spec_helper"

# Exercises the real routing constraints (controller specs bypass them) to
# confirm a profile's custom HTML renders, and the embed gets the strict CSP,
# on a seller's own custom domain — the watch-out flagged in the issue.
describe "Profile custom HTML rendering", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:seller) { create(:user, username: "customprofile", name: "Jane Doe") }
  let!(:custom_domain) { create(:custom_domain, :verified_with_certificate, user: seller, domain: "seller.example.com") }

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

  it "forbids shared caching of the embed, whose prices are derived from the visitor's IP" do
    get "http://seller.example.com/landing/embed"

    directives = response.headers["Cache-Control"].split(",").map(&:strip)
    expect(directives).to include("private")
    expect(directives).to include("no-store")
    expect(directives).not_to include("public")
    expect(response.headers["Cache-Control"]).not_to match(/s-maxage/)
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

  describe "share card meta tags" do
    # The wrapper builds its own <head>, so it never saw PageMeta::User's
    # subscribe-preview card (gumroad-private#1548).
    it "serves the branded subscribe-preview card on og:image and twitter:image" do
      seller.subscribe_preview.attach(
        io: File.open(Rails.root.join("spec", "support", "fixtures", "subscribe_preview.png")),
        filename: "subscribe_preview.png",
        content_type: "image/png"
      )

      get "http://seller.example.com/"

      expect(seller.subscribe_preview_url).to be_present
      expect(response.body).to include(%(<meta property="og:image" content="#{ERB::Util.h(seller.subscribe_preview_url)}">))
      expect(response.body).to include(%(<meta property="twitter:image" content="#{ERB::Util.h(seller.subscribe_preview_url)}">))
      expect(response.body).to include(%(<meta property="twitter:card" content="summary_large_image">))
      expect(response.body).to include(%(<meta property="og:image:alt" content="Jane Doe">))
      expect(response.body).to include(%(<meta property="og:image:type" content="image/png">))
      expect(response.body).to include(%(<meta property="og:image:width" content="#{SubscribePreviewGeneratorService::OUTPUT_WIDTH}">))
      expect(response.body).to include(%(<meta property="og:image:height" content="#{SubscribePreviewGeneratorService::OUTPUT_HEIGHT}">))
    end

    it "falls back to an uploaded avatar with no twitter card" do
      seller.avatar.attach(
        io: File.open(Rails.root.join("spec", "support", "fixtures", "smilie.png")),
        filename: "smilie.png",
        content_type: "image/png"
      )

      get "http://seller.example.com/"

      expect(seller.subscribe_preview_url).to be_nil
      expect(response.body).to include(%(<meta property="og:image" content="#{ERB::Util.h(seller.avatar_url)}">))
      expect(response.body).to include(%(<meta property="og:image:alt" content="Jane Doe's profile picture">))
      expect(response.body).not_to include(%(property="twitter:image"))
      expect(response.body).not_to include(%(property="twitter:card"))
      # Dimensions describe the generated card PNG only, never an avatar upload.
      expect(response.body).not_to include(%(property="og:image:width"))
    end

    # The common case for an established seller, and the one that pins the chain's
    # ORDER: with only one asset attached either precedence passes.
    it "prefers the branded card over an uploaded avatar when the seller has both" do
      seller.avatar.attach(
        io: File.open(Rails.root.join("spec", "support", "fixtures", "smilie.png")),
        filename: "smilie.png",
        content_type: "image/png"
      )
      seller.subscribe_preview.attach(
        io: File.open(Rails.root.join("spec", "support", "fixtures", "subscribe_preview.png")),
        filename: "subscribe_preview.png",
        content_type: "image/png"
      )

      get "http://seller.example.com/"

      expect(response.body).to include(%(<meta property="og:image" content="#{ERB::Util.h(seller.subscribe_preview_url)}">))
      # avatar_url legitimately appears elsewhere in <head> now (favicon links,
      # gp#1966) — scope the "avatar lost the og:image race" assertion to the
      # og:image tag itself instead of the whole document.
      expect(response.body).not_to include(%(<meta property="og:image" content="#{ERB::Util.h(seller.avatar_url)}">))
      expect(response.body).to include(%(<meta property="og:image:alt" content="Jane Doe">))
    end

    # This hand-built <head> gets none of PageMeta::Base's defaults, so without an
    # explicit fallback the wrapper advertised no image at all while the standard
    # profile advertised the generic banner — the two surfaces disagreeing.
    it "falls back to Gumroad's generic banner when the seller has neither" do
      get "http://seller.example.com/"

      expect(response.body).to include(%(<meta property="og:image" content="#{ERB::Util.h(ActionController::Base.helpers.image_url("opengraph_image.png"))}">))
      expect(response.body).to include(%(<meta property="og:image:alt" content="Gumroad">))
      # The favicon links (gp#1966) legitimately point at the default avatar
      # asset when none is uploaded — only the og:image tag itself must avoid it.
      expect(response.body).not_to include(%(<meta property="og:image" content="#{ERB::Util.h(ActionController::Base.helpers.image_url("gumroad-default-avatar-5.png"))}">))
      expect(response.body).not_to include(%(property="twitter:image"))
    end
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

      # Scoped to the STORE_HOSTNAMES declarations, not the whole document: a
      # shared host now also appears in GUMROAD_NAV_HOSTS, where it is reachable
      # by exact GLOBAL_NAV_PATHS only. A bare body-wide `not_to include` would
      # fail on that legitimate occurrence, and relaxing it away would delete the
      # only assertion protecting the seller-controlled allowlist.
      store_hostname_decls = response.body.scan(/STORE_HOSTNAMES = (\[[^\]]*\])/).flatten
      expect(store_hostname_decls).not_to be_empty
      store_hostname_decls.each do |decl|
        VALID_REQUEST_HOSTS.each do |shared_host|
          expect(decl).not_to include("\"#{shared_host}\"")
        end
      end
    end

    it "reaches Gumroad's own account and cart pages by exact path, on a host no seller controls" do
      get "http://seller.example.com/"

      # The canonical host is deliberately absent from STORE_HOSTNAMES (above),
      # so this is the only route to /library and /checkout — and it resolves an
      # exact path, dropping anything the sandbox appended.
      expect(response.body).to include(%(GUMROAD_NAV_HOSTS = #{VALID_REQUEST_HOSTS.to_json}))
      expect(response.body).to include(%(GUMROAD_NAV_PATHS = #{RendersCustomHtmlPages::GLOBAL_NAV_PATHS.to_json}))
      expect(response.body).to include("if (GUMROAD_NAV_PATHS.indexOf(path) === -1) return null;")
      expect(response.body).to include("return url.origin + path;")
    end

    it "keeps the iframe sandbox unchanged — still no allow-same-origin or allow-top-navigation" do
      get "http://seller.example.com/"

      expect(response.body).to include(%(sandbox="#{RendersCustomHtmlPages::CUSTOM_HTML_SANDBOX}"))
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
      # Opaque-origin e.origin isn't usable (Chrome reports "null", other
      # engines report the frame URL). Gate on e.source only.
      expect(response.body).not_to include('e.origin !== "null"')
      expect(response.body).to include("e.source !== frame.contentWindow")
    end

    # These two examples are about ROUTING: that the follow endpoint is
    # reachable on the hosts the sandboxed wrapper actually fetches it from. The
    # seller therefore has to be one whose follows are accepted at all, so a
    # refusal can't be mistaken for a missing route. A seller we have not
    # reviewed is refused outright on this endpoint — the copy-pasted embed form
    # lives on someone else's website and has no CAPTCHA for the visitor to
    # solve, so there is nothing to challenge (see FollowRecaptcha and
    # FollowersController#from_embed_form). Coverage of that refusal, including
    # the subscribe-page fallback it offers instead, lives in
    # spec/controllers/followers_controller_spec.rb.
    context "for a seller we have reviewed and marked compliant" do
      before { seller.update!(user_risk_state: "compliant") }

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
      expect(data.keys).to match_array(%w[products posts pages products_total posts_total])
      expect(data["products"].map { _1["name"] }).to include("Cool thing")
      expect(data["products"].first.keys).to match_array(%w[name url price native_type thumbnail_url cover_url description])
    end

    it "adds seller_rating to the payload only once the seller_reputation_summary flag is on" do
      create(:product, user: seller, name: "Cool thing")
      Feature.activate_user(:seller_reputation_summary, seller)

      get "http://seller.example.com/landing/embed"

      json = response.body[%r{<script id="gumroad-data"[^>]*>(.*?)</script>}m, 1]
      expect(JSON.parse(json).keys).to match_array(%w[products posts pages products_total posts_total seller_rating])
    end

    it "embeds a per-request price blob keyed by permalink alongside the cached catalog" do
      product = create(:product, user: seller, name: "Cool thing", price_cents: 1400)
      seller.update!(custom_html: %(<main><script>document.getElementById("gumroad-prices")</script></main>))

      get "http://seller.example.com/landing/embed"

      json = response.body[%r{<script id="gumroad-prices"[^>]*>(.*?)</script>}m, 1]
      prices = JSON.parse(json)
      expect(prices[product.general_permalink]).to eq(
        "price" => "$14", "price_cents" => 1400, "currency_code" => "usd", "localized" => false
      )
    end

    # The build is per-request work for up to 100 products; a page that references neither the
    # blob's id nor a product-scoped field cannot consume it, so it must not pay for it.
    it "omits the price blob when the page references no price surface" do
      create(:product, user: seller, price_cents: 1400)

      get "http://seller.example.com/landing/embed"

      expect(response.body).to include(%(id="gumroad-data"))
      expect(response.body).not_to include(%(id="gumroad-prices"))
    end

    it "interpolates a product-scoped price into the seller's markup" do
      product = create(:product, user: seller, price_cents: 3900)
      seller.update!(custom_html: %(<span data-gumroad-product="#{product.general_permalink}" data-gumroad-field="price">$0</span>))

      get "http://seller.example.com/landing/embed"

      expect(response.body).to include(">$39<")
      expect(response.body).not_to include(">$0<")
    end

    # The one example that would catch the request wiring degrading to no IP: without
    # request.remote_ip reaching the service, every visitor falls back to seller currency and
    # nothing else in the suite notices.
    it "localizes the blob to the visitor's own currency, from the request IP" do
      product = create(:product, user: seller, price_cents: 1400)
      seller.update!(custom_html: %(<main><script>document.getElementById("gumroad-prices")</script></main>))
      allow(Feature).to receive(:active?).and_call_original
      allow(Feature).to receive(:active?).with(:buyer_local_currency, seller).and_return(true)
      allow(GeoIp).to receive(:lookup).and_return(
        GeoIp::Result.new(country_name: "France", country_code: "FR", region_name: nil,
                          city_name: nil, postal_code: nil, latitude: nil, longitude: nil)
      )
      allow_any_instance_of(Pages::ProductPrices).to receive(:buyer_local_currency_rate).and_return(BigDecimal("0.8"))

      get "http://seller.example.com/landing/embed"

      prices = JSON.parse(response.body[%r{<script id="gumroad-prices"[^>]*>(.*?)</script>}m, 1])
      expect(prices[product.general_permalink]).to eq(
        "price" => "€11.20", "price_cents" => 1120, "currency_code" => "eur", "localized" => true
      )
      # The mutation this catches: passing `ip: nil` instead of request.remote_ip still renders a
      # blob, just never a localized one.
      expect(GeoIp).to have_received(:lookup).with("127.0.0.1").at_least(:once)
    end

    # The served page must localize a membership the way the native card does — recurrence
    # wording included — now that checkout can charge one in the buyer's currency (#6495).
    # The service specs pin the gate; this pins the page a visitor actually receives, on
    # both price surfaces at once (the blob and the interpolated markup).
    it "serves a localized membership price with its recurrence wording, in the blob and the markup" do
      membership = create(:membership_product, user: seller, price_cents: 500)
      seller.update!(custom_html: %(<main><span data-gumroad-product="#{membership.general_permalink}" data-gumroad-field="price">$5 a month</span><script>document.getElementById("gumroad-prices")</script></main>))
      allow(Feature).to receive(:active?).and_call_original
      allow(Feature).to receive(:active?).with(:buyer_local_currency, seller).and_return(true)
      allow(GeoIp).to receive(:lookup).and_return(
        GeoIp::Result.new(country_name: "France", country_code: "FR", region_name: nil,
                          city_name: nil, postal_code: nil, latitude: nil, longitude: nil)
      )
      allow_any_instance_of(Pages::ProductPrices).to receive(:buyer_local_currency_rate).and_return(BigDecimal("0.8"))

      get "http://seller.example.com/landing/embed"

      prices = JSON.parse(response.body[%r{<script id="gumroad-prices"[^>]*>(.*?)</script>}m, 1])
      expect(prices[membership.general_permalink]).to eq(
        "price" => "€4 a month", "price_cents" => 400, "currency_code" => "eur", "localized" => true
      )
      expect(response.body).to include(">€4 a month<")
      expect(response.body).not_to include(">$5 a month<")
    end
  end

  describe "preview field sync" do
    it "includes the name/bio live-update listener on the owner's ?preview embed" do
      sign_in seller
      get "http://seller.example.com/landing/embed?preview=true"
      expect(response.body).to include("gumroad:profile-fields")
    end

    # The server-side interpolator never answers a product-scoped element with a profile field;
    # the live preview must match, or editing the name would overwrite product cards on screen.
    it "excludes product-scoped elements from the live sync" do
      sign_in seller
      get "http://seller.example.com/landing/embed?preview=true"
      expect(response.body).to include(":not([data-gumroad-product])")
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
