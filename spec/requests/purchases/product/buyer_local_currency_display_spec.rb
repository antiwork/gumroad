# frozen_string_literal: true

require "spec_helper"

describe "Buyer-local currency display (#5281)", type: :system, js: true do
  let(:currency_namespace) { Redis::Namespace.new(:currencies, redis: $redis) }
  let(:rate_cache_key) { "buyer_local_currency_rate:usd:eur:#{Date.current}" }
  let(:stale_rate_cache_key) { "buyer_local_currency_rate:usd:eur:latest" }

  let(:france) do
    GeoIp::Result.new(
      country_name: "France", country_code: "FR", region_name: "IDF",
      city_name: "Paris", postal_code: "75001", latitude: nil, longitude: nil
    )
  end
  let(:united_states) do
    GeoIp::Result.new(
      country_name: "United States", country_code: "US", region_name: "CA",
      city_name: "San Francisco", postal_code: "94110", latitude: nil, longitude: nil
    )
  end

  before { currency_namespace.set(rate_cache_key, "0.8") }

  after do
    currency_namespace.del(rate_cache_key)
    currency_namespace.del(stale_rate_cache_key)
  end

  # The GA events are gated client-side on shouldTrack() (the
  # gr:google_analytics:enabled meta tag, always "false" outside prod/staging)
  # and on the external gtag script having loaded — neither holds headless.
  # Inject a capturing gtag and force shouldTrack() true before any page script
  # runs so the real firing path is exercised and asserted.
  def capture_gtag_events
    page.driver.browser.execute_cdp(
      "Page.addScriptToEvaluateOnNewDocument",
      source: <<~JS
        window.__gaEvents = [];
        window.gtag = function () { window.__gaEvents.push(Array.prototype.slice.call(arguments)); };
        (function () {
          var GA_ENABLED_META = 'meta[property="gr:google_analytics:enabled"]';
          var nativeQuerySelector = Document.prototype.querySelector;
          Document.prototype.querySelector = function (selector) {
            if (selector === GA_ENABLED_META) return { getAttribute: function () { return "true"; } };
            return nativeQuerySelector.apply(this, arguments);
          };
        })();
      JS
    )
  end

  def wait_for_gtag_event(event_name)
    finder = <<~JS
      (window.__gaEvents || []).find(function (call) {
        return call[0] === "event" && call[1] === #{event_name.to_json};
      }) || null
    JS
    event = nil
    Timeout.timeout(Capybara.default_max_wait_time) do
      loop do
        event = page.evaluate_script(finder)
        break if event
        sleep 0.1
      end
    end
    event
  end

  context "when an opted-in seller's USD product is viewed from a EUR country" do
    before do
      allow(GeoIp).to receive(:lookup).and_return(france)
      @seller = create(:user_with_compliance_info, show_buyer_local_currency: true, google_analytics_id: "G-TESTGA1234")
      @product = create(:product, user: @seller, price_cents: 10_00)
    end

    it "shows the EUR-localized price on the product page, the USD charge on checkout, and records the purchase in USD" do
      visit "/l/#{@product.unique_permalink}"

      expect(page).to have_text("€8.00", normalize_ws: true)
      expect(page).to have_no_text("$10")

      # Charge currency is product-scoped, not geolocation. Resolve to US for the
      # checkout leg to keep this off the EU-VAT path (separate coverage).
      allow(GeoIp).to receive(:lookup).and_return(united_states)

      add_to_cart(@product)
      check_out(@product) do
        expect(page).to have_text("US$10", normalize_ws: true)
        expect(page).to have_no_text("€")
      end

      purchase = Purchase.successful.last
      expect(purchase.link_id).to eq(@product.id)
      expect(purchase.price_cents).to eq(10_00)
      expect(purchase.displayed_price_currency_type.to_s).to eq("usd")
    end

    it "fires the buyer_currency_display_view GA event with the buyer-local payload" do
      capture_gtag_events
      visit "/l/#{@product.unique_permalink}"

      expect(page).to have_text("€8.00", normalize_ws: true)

      payload = wait_for_gtag_event("buyer_currency_display_view").last
      expect(payload).to include(
        "product_id" => @product.external_id,
        "creator_opted_in" => true,
        "buyer_currency_shown" => "eur",
        "product_currency" => "usd",
        "buyer_local_price_cents" => 800,
        "rate" => 0.8,
        "variant" => "buyer_local",
        "send_to" => "gumroad",
      )
    end
  end

  context "when the same opted-in product is viewed from the US" do
    before do
      allow(GeoIp).to receive(:lookup).and_return(united_states)
      @seller = create(:user_with_compliance_info, show_buyer_local_currency: true, google_analytics_id: "G-TESTGA1234")
      @product = create(:product, user: @seller, price_cents: 10_00)
    end

    it "shows the default USD price with no localized currency" do
      visit "/l/#{@product.unique_permalink}"

      expect(page).to have_text("$10", normalize_ws: true)
      expect(page).to have_no_text("€")
    end

    it "does not fire the buyer_currency_display_view GA event for a US buyer" do
      capture_gtag_events
      visit "/l/#{@product.unique_permalink}"

      expect(page).to have_text("$10", normalize_ws: true)

      wait_for_gtag_event("view_item")
      bcd_event_count = page.evaluate_script(
        "(window.__gaEvents || []).filter(function (c) { return c[1] === 'buyer_currency_display_view'; }).length"
      )
      expect(bcd_event_count).to eq(0)
    end
  end

  context "when the seller has not opted in" do
    before do
      allow(GeoIp).to receive(:lookup).and_return(france)
      @seller = create(:user_with_compliance_info, show_buyer_local_currency: false)
      @product = create(:product, user: @seller, price_cents: 10_00)
    end

    it "shows the default USD price even for a EUR-country buyer" do
      visit "/l/#{@product.unique_permalink}"

      expect(page).to have_text("$10", normalize_ws: true)
      expect(page).to have_no_text("€")
    end
  end

  context "when the currency-rate cache is cold" do
    before do
      currency_namespace.del(rate_cache_key)
      currency_namespace.del(stale_rate_cache_key)
      allow(GeoIp).to receive(:lookup).and_return(france)
      @seller = create(:user_with_compliance_info, show_buyer_local_currency: true)
      @product = create(:product, user: @seller, price_cents: 10_00)
    end

    it "falls back to the default USD price for a EUR-country buyer" do
      visit "/l/#{@product.unique_permalink}"

      expect(page).to have_text("$10", normalize_ws: true)
      expect(page).to have_no_text("€")
    end
  end
end
