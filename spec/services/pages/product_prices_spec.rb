# frozen_string_literal: true

require "spec_helper"

describe Pages::ProductPrices do
  let(:seller) { create(:user, disable_buyer_local_currency: false) }
  let!(:product) { create(:product, user: seller, name: "Quicklauncher", price_cents: 1400, price_currency_type: "usd") }
  let(:french_ip) { "2.2.2.2" }

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
      Feature.activate(:buyer_local_currency)
      stub_geoip(french_ip, "FR")
      allow_any_instance_of(described_class).to receive(:buyer_local_currency_rate).and_return(BigDecimal("0.8"))

      entry = described_class.build(seller, ip: french_ip)[product.general_permalink]

      expect(entry).to eq(price: "€11.20", price_cents: 1120, currency_code: "eur", localized: true)
    end

    it "falls back to the seller's price when the creator has opted out of buyer-local currency" do
      Feature.activate(:buyer_local_currency)
      seller.update!(disable_buyer_local_currency: true)
      stub_geoip(french_ip, "FR")
      allow_any_instance_of(described_class).to receive(:buyer_local_currency_rate).and_return(BigDecimal("0.8"))

      entry = described_class.build(seller, ip: french_ip)[product.general_permalink]

      expect(entry).to eq(price: "$14", price_cents: 1400, currency_code: "usd", localized: false)
    end

    it "falls back to the seller's price when no exchange rate is cached" do
      Feature.activate(:buyer_local_currency)
      stub_geoip(french_ip, "FR")
      allow_any_instance_of(described_class).to receive(:buyer_local_currency_rate).and_return(nil)

      entry = described_class.build(seller, ip: french_ip)[product.general_permalink]

      expect(entry[:localized]).to be(false)
      expect(entry[:currency_code]).to eq("usd")
    end

    it "keeps the pay-what-you-want indicator on a localized price" do
      product.update!(customizable_price: true)
      Feature.activate(:buyer_local_currency)
      stub_geoip(french_ip, "FR")
      allow_any_instance_of(described_class).to receive(:buyer_local_currency_rate).and_return(BigDecimal("0.8"))

      entry = described_class.build(seller, ip: french_ip)[product.general_permalink]

      expect(entry[:price]).to eq("€11.20+")
    end

    # A membership's price carries a recurrence suffix that a converted amount cannot honor,
    # and buyer_currency_settleable? refuses recurring products for exactly that reason.
    it "leaves a membership on the seller's own price and recurrence wording" do
      membership = create(:membership_product, user: seller, price_cents: 500)
      Feature.activate(:buyer_local_currency)
      stub_geoip(french_ip, "FR")
      allow_any_instance_of(described_class).to receive(:buyer_local_currency_rate).and_return(BigDecimal("0.8"))

      entry = described_class.build(seller, ip: french_ip)[membership.general_permalink]

      expect(entry[:localized]).to be(false)
      expect(entry[:price]).to eq(membership.price_formatted_verbose)
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
      Feature.activate(:buyer_local_currency)
      stub_geoip(french_ip, "FR")
      create_list(:product, 3, user: seller)

      described_class.build(seller, ip: french_ip)

      expect(GeoIp).to have_received(:lookup).once
    end

    it "is not memoized across requests, so a price edit is reflected immediately" do
      described_class.build(seller, ip: nil)
      product.update!(price_cents: 3900)

      entry = described_class.build(seller.reload, ip: nil)[product.general_permalink]

      expect(entry[:price_cents]).to eq(3900)
    end
  end
end
