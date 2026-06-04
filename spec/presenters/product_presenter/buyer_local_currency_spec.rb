# frozen_string_literal: true

require "spec_helper"

describe "ProductPresenter buyer local currency props" do
  let(:seller) { create(:user, disable_buyer_local_currency: false) }
  let(:product) { create(:product, user: seller, price_cents: 1000, price_currency_type: "usd") }

  let(:request) do
    OpenStruct.new(
      remote_ip: "2.2.2.2",
      host: "example.com",
      host_with_port: "example.com",
      cookie_jar: {}
    )
  end

  before do
    Feature.activate(:buyer_local_currency)
    allow(GeoIp).to receive(:lookup).with("2.2.2.2").and_return(
      GeoIp::Result.new(
        country_name: "France",
        country_code: "FR",
        region_name: nil,
        city_name: nil,
        postal_code: nil,
        latitude: nil,
        longitude: nil
      )
    )
  end

  def set_default_offer_code(product)
    offer_code = product.user.offer_codes.create!(
      code: "HALF#{product.id}",
      amount_percentage: 50,
      products: [product]
    )
    product.update!(default_offer_code: offer_code)
  end

  describe ProductPresenter::ProductProps do
    it "includes buyer local price when the creator has not opted out and the buyer currency is non-primary" do
      allow_any_instance_of(described_class).to receive(:buyer_local_currency_rate).and_return(BigDecimal("0.8"))

      props = described_class.new(product:).props(seller_custom_domain_url: nil, request:, pundit_user: nil)[:product]

      expect(props[:buyer_currency]).to eq("eur")
      expect(props[:buyer_local_currency_rate]).to eq(0.8)
      expect(props[:buyer_local_currency_subunit_to_unit]).to eq(100)
      expect(props[:buyer_local_price_cents]).to eq(800)
      expect(props[:buyer_currency_display]).to eq(
        product_id: product.external_id,
        buyer_currency_shown: "eur",
        product_currency: "usd",
        buyer_local_price_cents: 800,
        rate: 0.8,
        display_mode: "buyer_local"
      )
    end

    it "includes buyer local price and original price for an enabled discounted product" do
      set_default_offer_code(product)
      allow_any_instance_of(described_class).to receive(:buyer_local_currency_rate).and_return(BigDecimal("0.8"))

      props = described_class.new(product:).props(seller_custom_domain_url: nil, request:, pundit_user: nil)[:product]

      expect(props[:buyer_currency]).to eq("eur")
      expect(props[:buyer_local_currency_rate]).to eq(0.8)
      expect(props[:buyer_local_price_cents]).to eq(400)
      expect(props[:buyer_local_original_price_cents]).to eq(800)
    end

    it "omits buyer local price when the creator has opted out" do
      seller.update!(disable_buyer_local_currency: true)
      set_default_offer_code(product)
      allow_any_instance_of(described_class).to receive(:buyer_local_currency_rate).and_return(BigDecimal("0.8"))

      props = described_class.new(product:).props(seller_custom_domain_url: nil, request:, pundit_user: nil)[:product]

      expect(props).not_to have_key(:buyer_currency)
      expect(props).not_to have_key(:buyer_local_currency_rate)
      expect(props).not_to have_key(:buyer_local_price_cents)
      expect(props).not_to have_key(:buyer_local_original_price_cents)
      expect(props[:buyer_currency_display]).to eq(
        product_id: product.external_id,
        buyer_currency_shown: "usd",
        product_currency: "usd",
        buyer_local_price_cents: nil,
        rate: nil,
        display_mode: "default"
      )
    end

    it "omits buyer local price when the buyer currency matches the product currency" do
      allow(GeoIp).to receive(:lookup).with("2.2.2.2").and_return(
        GeoIp::Result.new(
          country_name: "United States",
          country_code: "US",
          region_name: nil,
          city_name: nil,
          postal_code: nil,
          latitude: nil,
          longitude: nil
        )
      )

      props = described_class.new(product:).props(seller_custom_domain_url: nil, request:, pundit_user: nil)[:product]

      expect(props).not_to have_key(:buyer_currency)
      expect(props).not_to have_key(:buyer_local_currency_rate)
      expect(props).not_to have_key(:buyer_local_price_cents)
      expect(props).not_to have_key(:buyer_local_original_price_cents)
      expect(props[:buyer_currency_display]).to eq(
        product_id: product.external_id,
        buyer_currency_shown: "usd",
        product_currency: "usd",
        buyer_local_price_cents: nil,
        rate: nil,
        display_mode: "default"
      )
    end

    it "omits buyer local price when the buyer country is unknown" do
      product.alive_prices.update_all(currency: "eur")
      product.update!(price_currency_type: "eur")
      allow(GeoIp).to receive(:lookup).with("2.2.2.2").and_return(
        GeoIp::Result.new(
          country_name: "Unknown",
          country_code: "ZZ",
          region_name: nil,
          city_name: nil,
          postal_code: nil,
          latitude: nil,
          longitude: nil
        )
      )

      expect_any_instance_of(described_class).not_to receive(:buyer_local_currency_rate)

      props = described_class.new(product:).props(seller_custom_domain_url: nil, request:, pundit_user: nil)[:product]

      expect(props).not_to have_key(:buyer_currency)
      expect(props).not_to have_key(:buyer_local_currency_rate)
      expect(props).not_to have_key(:buyer_local_price_cents)
      expect(props[:buyer_currency_display]).to eq(
        product_id: product.external_id,
        buyer_currency_shown: "eur",
        product_currency: "eur",
        buyer_local_price_cents: nil,
        rate: nil,
        display_mode: "default"
      )
    end

    it "renders without error and omits buyer local price when the product has no active price" do
      product.alive_prices.update_all(deleted_at: Time.current)
      product.reload
      expect(product.price_cents).to be_nil
      allow_any_instance_of(described_class).to receive(:buyer_local_currency_rate).and_return(BigDecimal("0.8"))

      props = nil
      expect do
        props = described_class.new(product:).props(seller_custom_domain_url: nil, request:, pundit_user: nil)[:product]
      end.not_to raise_error

      expect(props).not_to have_key(:buyer_currency)
      expect(props).not_to have_key(:buyer_local_price_cents)
      expect(props[:buyer_currency_display]).to include(display_mode: "default", buyer_local_price_cents: nil, rate: nil)
    end
  end

  describe ProductPresenter::Card do
    it "includes buyer local price for product cards when the creator opts in" do
      allow_any_instance_of(described_class).to receive(:buyer_local_currency_rate).and_return(BigDecimal("0.8"))

      props = described_class.new(product:).for_web(request:)

      expect(props[:buyer_currency]).to eq("eur")
      expect(props[:buyer_local_currency_rate]).to eq(0.8)
      expect(props[:buyer_local_currency_subunit_to_unit]).to eq(100)
      expect(props[:buyer_local_price_cents]).to eq(800)
      expect(props[:buyer_currency_display]).to eq(
        product_id: product.external_id,
        buyer_currency_shown: "eur",
        product_currency: "usd",
        buyer_local_price_cents: 800,
        rate: 0.8,
        display_mode: "buyer_local"
      )
    end

    it "includes buyer local price and original price for product cards with a pre-discount price" do
      set_default_offer_code(product)
      allow_any_instance_of(described_class).to receive(:buyer_local_currency_rate).and_return(BigDecimal("0.8"))

      props = described_class.new(product:).for_web(request:)

      expect(props[:buyer_currency]).to eq("eur")
      expect(props[:buyer_local_currency_rate]).to eq(0.8)
      expect(props[:buyer_local_price_cents]).to eq(400)
      expect(props[:buyer_local_original_price_cents]).to eq(800)
    end

    it "omits buyer local price for product cards when the buyer country is unknown" do
      product.alive_prices.update_all(currency: "eur")
      product.update!(price_currency_type: "eur")
      allow(GeoIp).to receive(:lookup).with("2.2.2.2").and_return(
        GeoIp::Result.new(
          country_name: "Unknown",
          country_code: "ZZ",
          region_name: nil,
          city_name: nil,
          postal_code: nil,
          latitude: nil,
          longitude: nil
        )
      )

      expect_any_instance_of(described_class).not_to receive(:buyer_local_currency_rate)

      props = described_class.new(product:).for_web(request:)

      expect(props).not_to have_key(:buyer_currency)
      expect(props).not_to have_key(:buyer_local_currency_rate)
      expect(props).not_to have_key(:buyer_local_price_cents)
      expect(props[:buyer_currency_display]).to eq(
        product_id: product.external_id,
        buyer_currency_shown: "eur",
        product_currency: "eur",
        buyer_local_price_cents: nil,
        rate: nil,
        display_mode: "default"
      )
    end
  end
end
