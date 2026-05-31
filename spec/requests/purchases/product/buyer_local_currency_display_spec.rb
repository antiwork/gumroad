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

  context "when an opted-in seller's USD product is viewed from a EUR country" do
    before do
      allow(GeoIp).to receive(:lookup).and_return(france)
      @seller = create(:user_with_compliance_info, show_buyer_local_currency: true)
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
