# frozen_string_literal: true

require "spec_helper"
require "inertia_rails/rspec"

describe "Buyer-local currency end-to-end display (#5281)", type: :request, inertia: true do
  let(:eur_ip) { "2.47.255.255" } # Italy via spec/support/geoip_mocking.rb
  let(:us_ip) { "54.234.242.13" }

  let(:currency_cache) { Redis::Namespace.new(:currencies, redis: $redis) }

  before do
    Feature.activate(:buyer_local_currency)
    # USD-based rate kept warm hourly by UpdateCurrenciesWorker; the usd→eur cross rate is 0.8.
    currency_cache.set("EUR", "0.8")
    # Rack::Attack#throttle_by_params reads body.read on every request; on a
    # GET with no body that's nil → crash. Orthogonal to what we're testing.
    Rack::Attack.enabled = false
  end

  after do
    currency_cache.del("EUR")
    Rack::Attack.enabled = true
  end

  describe "GET /l/:permalink (product page Inertia props)" do
    let(:seller) do
      create(:user, disable_buyer_local_currency: false, google_analytics_id: "G-TESTGA1234")
    end
    let(:product) { create(:product, user: seller, price_cents: 1000, price_currency_type: "usd") }

    before { host! URI.parse(seller.subdomain_with_protocol).host }

    context "when an enabled seller's USD product is viewed from a EUR country" do
      it "renders the EUR-localized buyer_currency_display in the Inertia props" do
        get short_link_path(id: product.unique_permalink),
            headers: { "X-Inertia" => "true", "REMOTE_ADDR" => eur_ip }

        expect(response).to be_successful
        props = JSON.parse(response.body)["props"]["product"]

        expect(props["buyer_currency"]).to eq("eur")
        expect(props["buyer_local_price_cents"]).to eq(800)
        expect(props["buyer_local_currency_rate"]).to eq(0.8)
        expect(props["buyer_currency_display"]).to include(
          "product_id" => product.external_id,
          "buyer_currency_shown" => "eur",
          "product_currency" => "usd",
          "buyer_local_price_cents" => 800,
          "rate" => 0.8,
          "display_mode" => "buyer_local",
        )
      end

      it "preserves the USD product price unchanged (display is informational only)" do
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
          "buyer_currency_shown" => "usd",
          "product_currency" => "usd",
          "display_mode" => "default",
        )
      end
    end

    context "when the seller has opted out" do
      let(:seller) { create(:user, disable_buyer_local_currency: true) }

      it "renders the default variant even for an EU buyer" do
        get short_link_path(id: product.unique_permalink),
            headers: { "X-Inertia" => "true", "REMOTE_ADDR" => eur_ip }

        props = JSON.parse(response.body)["props"]["product"]

        expect(props).not_to have_key("buyer_currency")
        expect(props["buyer_currency_display"]).to include(
          "display_mode" => "default",
        )
      end
    end

    context "degraded mode: currency-rate cache cold (UpdateCurrenciesWorker has not warmed it)" do
      it "falls back to the default variant and does not break the product page" do
        currency_cache.del("EUR")

        get short_link_path(id: product.unique_permalink),
            headers: { "X-Inertia" => "true", "REMOTE_ADDR" => eur_ip }

        expect(response).to be_successful
        props = JSON.parse(response.body)["props"]["product"]
        expect(props["buyer_currency_display"]).to include("display_mode" => "default")
        expect(props).not_to have_key("buyer_local_price_cents")
      end
    end
  end

  describe "GET /r/:token (receipt page seller_analytics)" do
    let(:seller) do
      create(:user, disable_buyer_local_currency: false, google_analytics_id: "G-TESTGA9999")
    end
    let(:product) { create(:product, user: seller, price_cents: 1000) }
    let(:purchase) do
      create(:purchase, link: product, ip_address: eur_ip, email: "eur-buyer@example.com")
    end
    let(:url_redirect) { create(:url_redirect, purchase: purchase, link: product) }

    before { host! URI.parse(seller.subdomain_with_protocol).host }

    it "includes buyer_currency_display in seller_analytics.purchase_event for a EUR buyer" do
      get url_redirect_download_page_path(id: url_redirect.token),
          headers: { "X-Inertia" => "true", "REMOTE_ADDR" => purchase.ip_address }

      expect(response).to be_successful
      props = JSON.parse(response.body)["props"]

      seller_analytics = props["seller_analytics"]
      expect(seller_analytics).to be_present

      event = seller_analytics["purchase_event"]
      expect(event).to include(
        "permalink" => product.unique_permalink,
        "purchase_external_id" => purchase.external_id,
        "currency" => "usd",
        "value" => 1000,
      )

      expect(event["buyer_currency_display"]).to include(
        "product_id" => product.external_id,
        "buyer_currency_shown" => "eur",
        "product_currency" => "usd",
        "buyer_local_price_cents" => 800,
        "rate" => 0.8,
        "display_mode" => "buyer_local",
      )
    end

    it "omits buyer_currency_display.display_mode=buyer_local for a US buyer's purchase" do
      purchase.update!(ip_address: us_ip)

      get url_redirect_download_page_path(id: url_redirect.token),
          headers: { "X-Inertia" => "true", "REMOTE_ADDR" => us_ip }

      event = JSON.parse(response.body)["props"]["seller_analytics"]["purchase_event"]
      expect(event["buyer_currency_display"]).to include("display_mode" => "default")
    end

    context "when the seller has no third-party analytics configured" do
      let(:seller) { create(:user, disable_buyer_local_currency: false) }

      it "omits seller_analytics entirely (no GA/Pixel/TikTok IDs set)" do
        get url_redirect_download_page_path(id: url_redirect.token),
            headers: { "X-Inertia" => "true", "REMOTE_ADDR" => purchase.ip_address }

        expect(response).to be_successful
        props = JSON.parse(response.body)["props"]
        expect(props["seller_analytics"]).to be_nil
      end
    end
  end
end
