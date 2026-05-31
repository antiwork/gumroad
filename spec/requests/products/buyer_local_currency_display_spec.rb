# frozen_string_literal: true

require "spec_helper"
require "inertia_rails/rspec"

# End-to-end request specs for the buyer-local-currency display feature added in
# PR #5281. These hit real Rails endpoints (product page show + receipt
# url_redirect page) and exercise the full controller → presenter → currency
# helper stack with NO helper mocks. They assert two things the unit specs
# cannot:
#
#   1. The Inertia JSON props served to the buyer's browser actually contain
#      the correct `buyer_currency_display` payload — including the analytics
#      `variant` field that downstream JS (user_analytics.ts) uses to decide
#      whether to emit a `buyer_currency_display_viewed` event.
#   2. The receipt page (`/r/:token`) — the page where the *purchased* event
#      fires — surfaces the same `buyer_currency_display` payload inside
#      `seller_analytics.purchase_event`. This is the analytics contract
#      DownloadPage/WithContent.tsx reads at `trackProductEvent({ action:
#      "purchased", buyer_currency_display: ... })`.
#
# A regression on either path would silently break the GA / Facebook Pixel
# variant exposure measurement — which is the whole point of shipping the
# feature opt-in behind an A/B-style flag in the first place.
#
# Geolocation runs through the real `GeoIp.lookup` (stubbed suite-wide at the
# fixture layer in spec/support/geoip_mocking.rb), so we use IP addresses that
# resolve to known countries there: an Italian IP (→ EUR) and a US IP. The
# currency rate goes through the real Redis-backed `currency_namespace` cache;
# we seed the day's rate directly so no external HTTP rate provider is hit.
describe "Buyer-local currency end-to-end display (#5281)", type: :request, inertia: true do
  # Resolves to Italy (→ eur) via spec/support/geoip_mocking.rb fixtures.
  let(:eur_ip) { "2.47.255.255" }
  # Resolves to the United States via the same fixtures.
  let(:us_ip) { "54.234.242.13" }

  let(:currency_cache) { Redis::Namespace.new(:currencies, redis: $redis) }
  let(:rate_cache_key) { "buyer_local_currency_rate:usd:eur:#{Date.current}" }
  let(:stale_rate_cache_key) { "buyer_local_currency_rate:usd:eur:latest" }

  before do
    # Seed the day's USD→EUR rate straight into the real Redis cache the helper
    # reads from. A rate of 0.8 turns a $10.00 product into €8.00 (800 minor
    # units), which the examples below assert on. No HTTP rate provider is hit
    # because the cache is warm.
    currency_cache.set(rate_cache_key, "0.8")

    # Rack::Attack's throttle_by_params blocks call req.json_params for every
    # request (the path filter is applied AFTER param evaluation, see
    # config/initializers/rack_attack.rb:77). On request specs with no body,
    # body.read returns nil and crashes the ensure block. Disable rate-limiting
    # for these specs — orthogonal to what we're testing.
    Rack::Attack.enabled = false
  end

  after do
    currency_cache.del(rate_cache_key)
    currency_cache.del(stale_rate_cache_key)
    Rack::Attack.enabled = true
  end

  describe "GET /l/:permalink (product page Inertia props)" do
    let(:seller) do
      create(
        :user,
        show_buyer_local_currency: true,
        google_analytics_id: "G-TESTGA1234",
      )
    end
    let(:product) { create(:product, user: seller, price_cents: 1000, price_currency_type: "usd") }

    before { host! URI.parse(seller.subdomain_with_protocol).host }

    context "when an opted-in seller's USD product is viewed from a EUR country" do
      it "renders the EUR-localized buyer_currency_display in the Inertia props" do
        get short_link_path(id: product.unique_permalink),
            headers: { "X-Inertia" => "true", "REMOTE_ADDR" => eur_ip }

        expect(response).to be_successful
        props = JSON.parse(response.body)["props"]["product"]

        expect(props["buyer_currency"]).to eq("eur")
        expect(props["buyer_local_price_cents"]).to eq(800)
        expect(props["buyer_local_currency_rate"]).to eq(0.8)

        # This is the analytics payload trackBuyerCurrencyDisplayView() reads.
        # The variant flag is what GoogleAnalytics.trackProductEvent uses to
        # gate the `buyer_currency_display_viewed` event.
        expect(props["buyer_currency_display"]).to include(
          "product_id" => product.external_id,
          "creator_opted_in" => true,
          "buyer_currency_shown" => "eur",
          "product_currency" => "usd",
          "buyer_local_price_cents" => 800,
          "rate" => 0.8,
          "variant" => "buyer_local",
        )
      end

      it "preserves the USD product price unchanged (display is informational only)" do
        # Critical regression guard: the buyer SEES EUR but the platform must
        # still charge USD. If product_props ever leaks the local currency
        # into the actual price_cents field, buyers could be billed in EUR.
        get short_link_path(id: product.unique_permalink),
            headers: { "X-Inertia" => "true", "REMOTE_ADDR" => eur_ip }

        props = JSON.parse(response.body)["props"]["product"]
        expect(props["price_cents"]).to eq(1000)
        expect(props["currency_code"] || props["price_currency_type"]).to satisfy { |c| c.nil? || c.to_s.downcase == "usd" }
      end
    end

    context "when the same product is viewed from the US" do
      it "renders the default variant with no local-currency fields" do
        get short_link_path(id: product.unique_permalink),
            headers: { "X-Inertia" => "true", "REMOTE_ADDR" => us_ip }

        props = JSON.parse(response.body)["props"]["product"]

        expect(props).not_to have_key("buyer_currency")
        expect(props).not_to have_key("buyer_local_price_cents")
        expect(props["buyer_currency_display"]).to include(
          "creator_opted_in" => true,
          "buyer_currency_shown" => "usd",
          "product_currency" => "usd",
          "variant" => "default",
        )
      end
    end

    context "when the seller has NOT opted in" do
      let(:seller) { create(:user, show_buyer_local_currency: false) }

      it "renders the default variant even for an EU buyer" do
        get short_link_path(id: product.unique_permalink),
            headers: { "X-Inertia" => "true", "REMOTE_ADDR" => eur_ip }

        props = JSON.parse(response.body)["props"]["product"]

        expect(props).not_to have_key("buyer_currency")
        expect(props["buyer_currency_display"]).to include(
          "creator_opted_in" => false,
          "variant" => "default",
        )
      end
    end

    context "degraded mode: currency-rate cache cold + sidekiq job has not yet warmed it" do
      it "falls back to the default variant and does not break the product page" do
        # Genuinely cold cache: no day rate and no stale fallback in Redis. The
        # helper enqueues a prewarm job and returns nil, so the presenter must
        # degrade to the default variant rather than 500.
        currency_cache.del(rate_cache_key)
        currency_cache.del(stale_rate_cache_key)

        get short_link_path(id: product.unique_permalink),
            headers: { "X-Inertia" => "true", "REMOTE_ADDR" => eur_ip }

        expect(response).to be_successful
        props = JSON.parse(response.body)["props"]["product"]
        expect(props["buyer_currency_display"]).to include("variant" => "default")
        expect(props).not_to have_key("buyer_local_price_cents")
      end
    end
  end

  describe "GET /r/:token (receipt page seller_analytics)" do
    # The receipt page is the only place the `purchased` analytics event fires
    # (see app/javascript/components/DownloadPage/WithContent.tsx). For the A/B
    # variant exposure to be measurable, the `buyer_currency_display` payload
    # must travel all the way through to `seller_analytics.purchase_event`.
    let(:seller) do
      create(
        :user,
        show_buyer_local_currency: true,
        google_analytics_id: "G-TESTGA9999",
      )
    end
    let(:product) { create(:product, user: seller, price_cents: 1000) }
    let(:purchase) do
      create(
        :purchase,
        link: product,
        ip_address: eur_ip,
        email: "eur-buyer@example.com",
      )
    end
    let(:url_redirect) { create(:url_redirect, purchase: purchase, link: product) }

    before { host! URI.parse(seller.subdomain_with_protocol).host }

    # The download page (`/d/:token`) is where the receipt's Inertia props —
    # including seller_analytics — are actually rendered; `/r/:token` only
    # redirects here. check_permissions grants access when the request IP
    # matches the purchase IP, so we send REMOTE_ADDR == purchase.ip_address
    # rather than faking a confirmation cookie or signing in the buyer.
    it "includes buyer_currency_display in seller_analytics.purchase_event for a EUR buyer" do
      get url_redirect_download_page_path(id: url_redirect.token),
          headers: { "X-Inertia" => "true", "REMOTE_ADDR" => purchase.ip_address }

      expect(response).to be_successful
      props = JSON.parse(response.body)["props"]

      seller_analytics = props["seller_analytics"]
      expect(seller_analytics).to be_present, "expected seller_analytics in receipt props"

      event = seller_analytics["purchase_event"]
      expect(event).to include(
        "permalink" => product.unique_permalink,
        "purchase_external_id" => purchase.external_id,
        "currency" => "usd",
        # value is in USD cents — analytics must still report USD as the
        # transacted currency; buyer_currency_display is the *display* layer.
        "value" => 1000,
      )

      expect(event["buyer_currency_display"]).to include(
        "product_id" => product.external_id,
        "creator_opted_in" => true,
        "buyer_currency_shown" => "eur",
        "product_currency" => "usd",
        "buyer_local_price_cents" => 800,
        "rate" => 0.8,
        "variant" => "buyer_local",
      )
    end

    it "omits buyer_currency_display.variant=buyer_local for a US buyer's purchase" do
      purchase.update!(ip_address: us_ip)

      get url_redirect_download_page_path(id: url_redirect.token),
          headers: { "X-Inertia" => "true", "REMOTE_ADDR" => us_ip }

      event = JSON.parse(response.body)["props"]["seller_analytics"]["purchase_event"]
      expect(event["buyer_currency_display"]).to include("variant" => "default")
    end

    context "when the seller has no third-party analytics configured" do
      let(:seller) { create(:user, show_buyer_local_currency: true) }

      it "omits seller_analytics entirely (no GA/Pixel/TikTok IDs set)" do
        # Mirrors UrlRedirectPresenter#seller_analytics_props guard: without an
        # external analytics destination, we don't even emit the section.
        get url_redirect_download_page_path(id: url_redirect.token),
            headers: { "X-Inertia" => "true", "REMOTE_ADDR" => purchase.ip_address }

        expect(response).to be_successful
        props = JSON.parse(response.body)["props"]
        expect(props["seller_analytics"]).to be_nil
      end
    end
  end
end
