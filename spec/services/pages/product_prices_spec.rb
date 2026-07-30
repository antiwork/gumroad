# frozen_string_literal: true

require "spec_helper"

describe Pages::ProductPrices do
  let(:seller) { create(:user, disable_buyer_local_currency: false) }
  let!(:product) { create(:product, user: seller, name: "Quicklauncher", price_cents: 1400, price_currency_type: "usd") }
  let(:french_ip) { "2.2.2.2" }

  # Stubbed rather than Feature.activate'd: Flipper's adapter is Redis, which is shared with
  # every other spec process on the machine, so writing the flag globally makes these examples
  # depend on — and interfere with — unrelated runs.
  def enable_buyer_local_currency(for_seller = seller)
    allow(Feature).to receive(:active?).and_call_original
    allow(Feature).to receive(:active?).with(:buyer_local_currency, for_seller).and_return(true)
  end

  def stub_geoip(ip, country_code)
    allow(GeoIp).to receive(:lookup).with(ip).and_return(
      GeoIp::Result.new(
        country_name: country_code,
        country_code:,
        region_name: nil,
        city_name: nil,
        postal_code: nil,
        latitude: nil,
        longitude: nil
      )
    )
  end

  describe ".build" do
    it "keys entries by the product's permalink" do
      expect(described_class.build(seller, ip: nil).keys).to eq([product.general_permalink])
    end

    it "uses the custom permalink when the product has one" do
      product.update!(custom_permalink: "quicklauncher")

      expect(described_class.build(seller, ip: nil).keys).to eq(["quicklauncher"])
    end

    it "emits the seller's own price when the visitor's currency cannot be resolved" do
      entry = described_class.build(seller, ip: nil)[product.general_permalink]

      expect(entry).to eq(price: "$14", price_cents: 1400, currency_code: "usd", localized: false)
    end

    it "emits the visitor's currency when the seller is opted in and the buyer is elsewhere" do
      enable_buyer_local_currency
      stub_geoip(french_ip, "FR")
      allow_any_instance_of(described_class).to receive(:buyer_local_currency_rate).and_return(BigDecimal("0.8"))

      entry = described_class.build(seller, ip: french_ip)[product.general_permalink]

      expect(entry).to eq(price: "€11.20", price_cents: 1120, currency_code: "eur", localized: true)
    end

    it "falls back to the seller's price when the creator has opted out of buyer-local currency" do
      enable_buyer_local_currency
      seller.update!(disable_buyer_local_currency: true)
      stub_geoip(french_ip, "FR")
      allow_any_instance_of(described_class).to receive(:buyer_local_currency_rate).and_return(BigDecimal("0.8"))

      entry = described_class.build(seller, ip: french_ip)[product.general_permalink]

      expect(entry).to eq(price: "$14", price_cents: 1400, currency_code: "usd", localized: false)
    end

    it "falls back to the seller's price when no exchange rate is cached" do
      enable_buyer_local_currency
      stub_geoip(french_ip, "FR")
      allow_any_instance_of(described_class).to receive(:buyer_local_currency_rate).and_return(nil)

      entry = described_class.build(seller, ip: french_ip)[product.general_permalink]

      expect(entry[:localized]).to be(false)
      expect(entry[:currency_code]).to eq("usd")
    end

    it "keeps the pay-what-you-want indicator on a localized price" do
      product.update!(customizable_price: true)
      enable_buyer_local_currency
      stub_geoip(french_ip, "FR")
      allow_any_instance_of(described_class).to receive(:buyer_local_currency_rate).and_return(BigDecimal("0.8"))

      entry = described_class.build(seller, ip: french_ip)[product.general_permalink]

      expect(entry[:price]).to eq("€11.20+")
    end

    # A membership's price carries a recurrence suffix that a converted amount cannot honor,
    # and buyer_currency_settleable? refuses recurring products for exactly that reason.
    it "leaves a membership on the seller's own price and recurrence wording" do
      membership = create(:membership_product, user: seller, price_cents: 500)
      enable_buyer_local_currency
      stub_geoip(french_ip, "FR")
      allow_any_instance_of(described_class).to receive(:buyer_local_currency_rate).and_return(BigDecimal("0.8"))

      entry = described_class.build(seller, ip: french_ip)[membership.general_permalink]

      expect(entry[:localized]).to be(false)
      expect(entry[:price]).to eq(membership.price_formatted_verbose)
    end

    it "takes the default offer code off, so the card cannot quote a price checkout would not honor" do
      offer_code = seller.offer_codes.create!(code: "half", amount_percentage: 50, products: [product])
      product.update!(default_offer_code: offer_code)

      entry = described_class.build(seller, ip: nil)[product.general_permalink]

      expect(entry).to eq(price: "$7", price_cents: 700, currency_code: "usd", localized: false)
    end

    it "leaves an existing-customers-only code on, since a first-time visitor does not get it" do
      owned = create(:product, user: seller)
      offer_code = seller.offer_codes.create!(code: "loyal", amount_percentage: 50, products: [product],
                                              existing_customers_only: true, ownership_products: [owned])
      product.update!(default_offer_code: offer_code)

      entry = described_class.build(seller, ip: nil)[product.general_permalink]

      expect(entry[:price_cents]).to eq(1400)
    end

    it "localizes the discounted price, not the list price" do
      offer_code = seller.offer_codes.create!(code: "half", amount_percentage: 50, products: [product])
      product.update!(default_offer_code: offer_code)
      enable_buyer_local_currency
      stub_geoip(french_ip, "FR")
      allow_any_instance_of(described_class).to receive(:buyer_local_currency_rate).and_return(BigDecimal("0.8"))

      entry = described_class.build(seller, ip: french_ip)[product.general_permalink]

      expect(entry).to eq(price: "€5.60", price_cents: 560, currency_code: "eur", localized: true)
    end

    it "skips deleted, archived and draft products, matching the gumroad-data payload" do
      create(:product, user: seller, deleted_at: Time.current)
      create(:product, user: seller, archived: true)
      create(:product, user: seller, draft: true)

      expect(described_class.build(seller, ip: nil).keys).to eq([product.general_permalink])
    end

    it "caps the payload at the same limit as the gumroad-data payload" do
      stub_const("Pages::ProfileData::MAX_ITEMS", 2)
      create_list(:product, 2, user: seller)

      expect(described_class.build(seller, ip: nil).size).to eq(2)
    end

    it "geolocates the visitor once regardless of catalogue size" do
      enable_buyer_local_currency
      stub_geoip(french_ip, "FR")
      create_list(:product, 3, user: seller)

      described_class.build(seller, ip: french_ip)

      expect(GeoIp).to have_received(:lookup).once
    end

    # Pages::ProfileData wraps its payload in a per-seller Rails.cache.fetch; this service must
    # not, or a visitor's price could be served to another visitor. Pinning the absence of the
    # cache rather than the observable freshness, because a price edit rotates the profile cache
    # key anyway and so proves nothing about where the prices were built.
    it "reads no cache, so a per-visitor price can never be served to a different visitor" do
      expect(Rails.cache).not_to receive(:fetch)

      described_class.build(seller, ip: nil)
    end
  end
end
