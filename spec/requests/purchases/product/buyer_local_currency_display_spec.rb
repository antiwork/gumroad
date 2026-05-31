# frozen_string_literal: true

require "spec_helper"

# True end-to-end (Capybara/Stripe.js) coverage for the buyer-local-currency
# display feature added in PR #5281. A request spec can only assert the Inertia
# props handed to the browser; these examples drive the real browser so they
# assert what a buyer actually *sees* rendered by PriceTag.tsx, and — for the
# opted-in EUR case — that completing the real checkout still records the
# purchase in the product's USD currency.
#
# Two things the buyer's IP controls run through GeoIp.lookup (already stubbed
# suite-wide in spec/support/geoip_mocking.rb by IP). In a system spec the
# browser reaches the app server at 127.0.0.1, which the suite maps to "no
# country" — so we override GeoIp.lookup per example to place the buyer in the
# country under test. This is the only mock: it sits at the geolocation
# boundary the test driver can't otherwise exercise.
#
# The USD→EUR rate goes through the real Redis-backed currency cache; we seed
# the day's rate directly (0.8 → a $10.00 product shows as €8.00) so no HTTP
# rate provider is hit.
#
# Note on scope: the GA/Pixel analytics payload (buyer_currency_display.variant)
# is NOT asserted here. It fires via gtag()/window.dataLayer only when
# shouldTrack() is true (a gr:google_analytics:enabled meta tag, off in test)
# and the external GoogleTagManager script has loaded — neither holds in a
# headless run. That analytics-props contract stays covered by the request spec
# at spec/requests/products/buyer_local_currency_display_spec.rb.
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

  before do
    # 0.8 turns the $10.00 product into €8.00. Warm cache ⇒ no HTTP rate lookup.
    currency_namespace.set(rate_cache_key, "0.8")
  end

  after do
    currency_namespace.del(rate_cache_key)
    currency_namespace.del(stale_rate_cache_key)
  end

  context "when an opted-in seller's USD product is viewed from a EUR country" do
    before do
      allow(GeoIp).to receive(:lookup).and_return(france)
      @seller = create(:user_with_compliance_info, show_buyer_local_currency: true)
      @product = create(:product, user: @seller, price_cents: 10_00)
    end

    it "shows the EUR-localized price on the product page yet records the purchase in USD" do
      visit "/l/#{@product.unique_permalink}"

      # The buyer SEES the localized EUR price (PriceTag.tsx →
      # formatMinorUnitPriceWithIntl): 10_00 cents * 0.8 = 800 → €8.00.
      expect(page).to have_text("€8.00", normalize_ws: true)
      expect(page).to have_no_text("$10")

      # The localized display is verified above. The charge currency is a
      # property of the product, not of geolocation, so we resolve the buyer to
      # the US for the checkout leg: it keeps the Stripe.js flow on the standard
      # US form and isolates this assertion from EU-VAT checkout mechanics
      # (a separate concern with its own coverage).
      allow(GeoIp).to receive(:lookup).and_return(united_states)

      add_to_cart(@product)
      check_out(@product)

      # Critical invariant: the display layer is informational only. The buyer
      # is charged — and the sale is recorded — in the product's USD currency,
      # never EUR. A regression that leaked the local currency into the charge
      # would bill buyers in the wrong currency.
      purchase = Purchase.successful.last
      expect(purchase.link_id).to eq(@product.id)
      expect(purchase.price_cents).to eq(10_00)
      expect(purchase.displayed_price_currency_type.to_s).to eq("usd")
    end
  end

  context "when the same opted-in product is viewed from the US" do
    before do
      allow(GeoIp).to receive(:lookup).and_return(united_states)
      @seller = create(:user_with_compliance_info, show_buyer_local_currency: true)
      @product = create(:product, user: @seller, price_cents: 10_00)
    end

    it "shows the default USD price with no localized currency" do
      visit "/l/#{@product.unique_permalink}"

      expect(page).to have_text("$10", normalize_ws: true)
      expect(page).to have_no_text("€")
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
      # Genuinely cold: no day rate and no stale fallback. The helper enqueues a
      # prewarm job and returns nil, so the page must degrade to USD, not 500.
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
