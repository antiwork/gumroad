# frozen_string_literal: true

require "spec_helper"

describe ShippingDestination do
  before :each do
    @product = create(:product)
  end

  it "it does not allow saving if the country code is nil or invalid" do
    @product.shipping_destinations << ShippingDestination.new(country_code: "dummy",
                                                              one_item_rate_cents: 10,
                                                              multiple_items_rate_cents: 10)

    expect(@product).to_not be_valid

    valid_shipping_destination = ShippingDestination.new(country_code: Compliance::Countries::USA.alpha2,
                                                         one_item_rate_cents: 10,
                                                         multiple_items_rate_cents: 10)

    @product.reload.shipping_destinations << valid_shipping_destination
    @product.save!

    expect(@product.shipping_destinations.first).to eq(valid_shipping_destination)
  end

  it "does not allow saving if the standalone rate or the combined rate is missing" do
    @product.shipping_destinations << ShippingDestination.new(country_code: Compliance::Countries::USA.alpha2,
                                                              one_item_rate_cents: 10)
    expect(@product).to_not be_valid

    @product.reload.shipping_destinations << ShippingDestination.new(country_code: Compliance::Countries::USA.alpha2,
                                                                     multiple_items_rate_cents: 10)
    expect(@product).to_not be_valid

    valid_shipping_destination = ShippingDestination.new(country_code: Compliance::Countries::USA.alpha2,
                                                         one_item_rate_cents: 10,
                                                         multiple_items_rate_cents: 10)

    @product.reload.shipping_destinations << valid_shipping_destination
    @product.save!

    expect(@product.shipping_destinations.first).to eq(valid_shipping_destination)
  end

  it "does not allow associating a single record with both a user and a product" do
    valid_shipping_destination1 = ShippingDestination.new(country_code: Compliance::Countries::USA.alpha2,
                                                          one_item_rate_cents: 10,
                                                          multiple_items_rate_cents: 10)

    valid_shipping_destination2 = ShippingDestination.new(country_code: Compliance::Countries::DEU.alpha2,
                                                          one_item_rate_cents: 10,
                                                          multiple_items_rate_cents: 10)

    @product.shipping_destinations << valid_shipping_destination1
    @product.save!

    expect(@product.shipping_destinations.first).to eq(valid_shipping_destination1)

    @product.user.shipping_destinations << valid_shipping_destination1
    @product.save!

    expect(@product.reload.user.shipping_destinations).to be_empty

    @product.user.reload.shipping_destinations << valid_shipping_destination2
    @product.save!

    expect(@product.user.shipping_destinations.first).to eq(valid_shipping_destination2)
  end

  it "does not allow duplicate entries for a country code for a product" do
    valid_shipping_destination = ShippingDestination.new(country_code: Compliance::Countries::USA.alpha2,
                                                         one_item_rate_cents: 20,
                                                         multiple_items_rate_cents: 10)

    @product.shipping_destinations << valid_shipping_destination
    @product.save!

    expect(@product.shipping_destinations.first).to eq(valid_shipping_destination)

    @product.shipping_destinations << ShippingDestination.new(country_code: Compliance::Countries::USA.alpha2,
                                                              one_item_rate_cents: 10,
                                                              multiple_items_rate_cents: 10)
    expect(@product).to_not be_valid
  end

  it "does not allow duplicate entries for a country code for a user" do
    valid_shipping_destination = ShippingDestination.new(country_code: ShippingDestination::Destinations::ELSEWHERE,
                                                         one_item_rate_cents: 20,
                                                         multiple_items_rate_cents: 10)

    @product.user.shipping_destinations << valid_shipping_destination
    @product.save!

    expect(@product.user.shipping_destinations.first).to eq(valid_shipping_destination)

    @product.user.shipping_destinations << ShippingDestination.new(country_code: ShippingDestination::Destinations::ELSEWHERE,
                                                                   one_item_rate_cents: 10,
                                                                   multiple_items_rate_cents: 10)
    @product.save!
    expect(@product.user.reload.shipping_destinations).to eq([valid_shipping_destination])
  end

  describe "#calculate_shipping_rate" do
    before do
      @shipping_destination = ShippingDestination.new(country_code: Compliance::Countries::USA.alpha2,
                                                      one_item_rate_cents: 20,
                                                      multiple_items_rate_cents: 10)
    end

    it "returns nil for quantity < 1" do
      expect(@shipping_destination.calculate_shipping_rate(quantity: -1)).to be_nil
    end

    it "returns one_item_rate_cents for quantity = 1" do
      expect(@shipping_destination.calculate_shipping_rate(quantity: 1)).to eq(20)
    end

    it "returns one_item_rate_cents + (quantity -1)*multiple_items_rate_cents for quantity > 1" do
      expect(@shipping_destination.calculate_shipping_rate(quantity: 2)).to eq(30)
      expect(@shipping_destination.calculate_shipping_rate(quantity: 3)).to eq(40)
      expect(@shipping_destination.calculate_shipping_rate(quantity: 6)).to eq(70)
    end
  end

  describe "#for_product_and_country_code" do
    it "returns nil if the destination country code is nil or the product is not physical" do
      link = create(:product)

      expect(ShippingDestination.for_product_and_country_code(product: link, country_code: nil)).to be_nil

      shipping_destination = ShippingDestination.new(country_code: Compliance::Countries::USA.alpha2, one_item_rate_cents: 20, multiple_items_rate_cents: 10)
      link.shipping_destinations << shipping_destination
      link.is_physical = false
      link.save!

      expect(ShippingDestination.for_product_and_country_code(product: link.reload, country_code: Compliance::Countries::USA.alpha2)).to be_nil

      link.is_physical = true
      link.shipping_destinations << ShippingDestination.new(country_code: ShippingDestination::Destinations::ELSEWHERE, one_item_rate_cents: 0, multiple_items_rate_cents: 0)

      expect(ShippingDestination.for_product_and_country_code(product: link, country_code: Compliance::Countries::USA.alpha2)).to eq(shipping_destination)
    end

    it "returns a configured shipping destination if there is a match" do
      link = create(:product)
      shipping_destination1 = ShippingDestination.new(country_code: Compliance::Countries::USA.alpha2, one_item_rate_cents: 20, multiple_items_rate_cents: 10)
      shipping_destination2 = ShippingDestination.new(country_code: Compliance::Countries::DEU.alpha2, one_item_rate_cents: 10, multiple_items_rate_cents: 5)
      shipping_destination3 = ShippingDestination.new(country_code: Compliance::Countries::GBR.alpha2, one_item_rate_cents: 10, multiple_items_rate_cents: 5)

      link.is_physical = true
      link.require_shipping = true
      link.shipping_destinations << shipping_destination1 << shipping_destination2 << shipping_destination3
      link.save!

      expect(ShippingDestination.for_product_and_country_code(product: link, country_code: Compliance::Countries::USA.alpha2)).to eq(shipping_destination1)
      expect(ShippingDestination.for_product_and_country_code(product: link, country_code: Compliance::Countries::DEU.alpha2)).to eq(shipping_destination2)
      expect(ShippingDestination.for_product_and_country_code(product: link, country_code: Compliance::Countries::GBR.alpha2)).to eq(shipping_destination3)

      expect(ShippingDestination.for_product_and_country_code(product: link, country_code: Compliance::Countries::ESP.alpha2)).to be_nil
    end

    it "returns a match for any country if there is a configuration for ELSEWHERE" do
      link = create(:product)

      shipping_destination = ShippingDestination.new(country_code: ShippingDestination::Destinations::ELSEWHERE, one_item_rate_cents: 20, multiple_items_rate_cents: 10)
      link.shipping_destinations << shipping_destination
      link.is_physical = true
      link.require_shipping = true
      link.save!

      expect(ShippingDestination.for_product_and_country_code(product: link, country_code: Compliance::Countries::USA.alpha2)).to eq(shipping_destination)
      expect(ShippingDestination.for_product_and_country_code(product: link, country_code: Compliance::Countries::DEU.alpha2)).to eq(shipping_destination)
      expect(ShippingDestination.for_product_and_country_code(product: link, country_code: Compliance::Countries::ESP.alpha2)).to eq(shipping_destination)
      expect(ShippingDestination.for_product_and_country_code(product: link, country_code: Compliance::Countries::GBR.alpha2)).to eq(shipping_destination)
    end

    it "returns a match for the specific country before matching ELSEWHERE" do
      link = create(:product)

      shipping_destination1 = ShippingDestination.new(country_code: ShippingDestination::Destinations::ELSEWHERE, one_item_rate_cents: 20, multiple_items_rate_cents: 10)
      shipping_destination2 = ShippingDestination.new(country_code: Compliance::Countries::DEU.alpha2, one_item_rate_cents: 10, multiple_items_rate_cents: 5)

      link.shipping_destinations << shipping_destination1 << shipping_destination2
      link.is_physical = true
      link.require_shipping = true
      link.save!

      expect(ShippingDestination.for_product_and_country_code(product: link, country_code: Compliance::Countries::USA.alpha2)).to eq(shipping_destination1)
      expect(ShippingDestination.for_product_and_country_code(product: link, country_code: Compliance::Countries::ESP.alpha2)).to eq(shipping_destination1)
      expect(ShippingDestination.for_product_and_country_code(product: link, country_code: Compliance::Countries::GBR.alpha2)).to eq(shipping_destination1)

      expect(ShippingDestination.for_product_and_country_code(product: link, country_code: Compliance::Countries::DEU.alpha2)).to eq(shipping_destination2)
    end

    describe "virtual countries" do
      it "returns a configured shipping destination if there is a match" do
        link = create(:product)
        shipping_destination1 = ShippingDestination.new(country_code: ShippingDestination::Destinations::EUROPE, one_item_rate_cents: 20, multiple_items_rate_cents: 10, is_virtual_country: true)
        shipping_destination2 = ShippingDestination.new(country_code: ShippingDestination::Destinations::ASIA, one_item_rate_cents: 10, multiple_items_rate_cents: 5, is_virtual_country: true)
        shipping_destination3 = ShippingDestination.new(country_code: ShippingDestination::Destinations::NORTH_AMERICA, one_item_rate_cents: 10, multiple_items_rate_cents: 5, is_virtual_country: true)

        link.is_physical = true
        link.require_shipping = true
        link.shipping_destinations << shipping_destination1 << shipping_destination2 << shipping_destination3
        link.save!

        expect(ShippingDestination.for_product_and_country_code(product: link, country_code: Compliance::Countries::ESP.alpha2)).to eq(shipping_destination1)
        expect(ShippingDestination.for_product_and_country_code(product: link, country_code: Compliance::Countries::DEU.alpha2)).to eq(shipping_destination1)
        expect(ShippingDestination.for_product_and_country_code(product: link, country_code: Compliance::Countries::FRA.alpha2)).to eq(shipping_destination1)

        expect(ShippingDestination.for_product_and_country_code(product: link, country_code: Compliance::Countries::IND.alpha2)).to eq(shipping_destination2)
        expect(ShippingDestination.for_product_and_country_code(product: link, country_code: Compliance::Countries::CHN.alpha2)).to eq(shipping_destination2)
        expect(ShippingDestination.for_product_and_country_code(product: link, country_code: Compliance::Countries::MNG.alpha2)).to eq(shipping_destination2)

        expect(ShippingDestination.for_product_and_country_code(product: link, country_code: Compliance::Countries::USA.alpha2)).to eq(shipping_destination3)
        expect(ShippingDestination.for_product_and_country_code(product: link, country_code: Compliance::Countries::MEX.alpha2)).to eq(shipping_destination3)
        expect(ShippingDestination.for_product_and_country_code(product: link, country_code: Compliance::Countries::CAN.alpha2)).to eq(shipping_destination3)

        expect(ShippingDestination.for_product_and_country_code(product: link, country_code: Compliance::Countries::NGA.alpha2)).to be_nil
      end

      it "returns a country match before a virtual country match" do
        link = create(:product)

        shipping_destination1 = ShippingDestination.new(country_code: Compliance::Countries::USA.alpha2, one_item_rate_cents: 20, multiple_items_rate_cents: 10)
        shipping_destination2 = ShippingDestination.new(country_code: ShippingDestination::Destinations::NORTH_AMERICA, one_item_rate_cents: 10, multiple_items_rate_cents: 5, is_virtual_country: true)
        link.shipping_destinations << shipping_destination1 << shipping_destination2
        link.is_physical = true
        link.require_shipping = true
        link.save!

        expect(ShippingDestination.for_product_and_country_code(product: link, country_code: Compliance::Countries::USA.alpha2)).to eq(shipping_destination1)
        expect(ShippingDestination.for_product_and_country_code(product: link, country_code: Compliance::Countries::MEX.alpha2)).to eq(shipping_destination2)
      end

      it "returns a match for a virtual country before matching ELSEWHERE" do
        link = create(:product)

        shipping_destination1 = ShippingDestination.new(country_code: ShippingDestination::Destinations::ELSEWHERE, one_item_rate_cents: 20, multiple_items_rate_cents: 10)
        shipping_destination2 = ShippingDestination.new(country_code: ShippingDestination::Destinations::NORTH_AMERICA, one_item_rate_cents: 10, multiple_items_rate_cents: 5, is_virtual_country: true)

        link.shipping_destinations << shipping_destination1 << shipping_destination2
        link.is_physical = true
        link.require_shipping = true
        link.save!

        expect(ShippingDestination.for_product_and_country_code(product: link, country_code: Compliance::Countries::USA.alpha2)).to eq(shipping_destination2)
        expect(ShippingDestination.for_product_and_country_code(product: link, country_code: Compliance::Countries::ESP.alpha2)).to eq(shipping_destination1)
        expect(ShippingDestination.for_product_and_country_code(product: link, country_code: Compliance::Countries::GBR.alpha2)).to eq(shipping_destination1)
      end
    end
  end
end
