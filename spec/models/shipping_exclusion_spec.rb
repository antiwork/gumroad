# frozen_string_literal: true

require "spec_helper"

describe ShippingExclusion do
  let(:product) { create(:physical_product) }

  # `:physical_product` ships to ELSEWHERE by default (every country), so replace rather than add.
  def set_destinations(*country_codes, on: product)
    on.shipping_destinations.alive.each(&:destroy)
    country_codes.each do |country_code|
      on.shipping_destinations << ShippingDestination.new(
        country_code:,
        one_item_rate_cents: 0,
        multiple_items_rate_cents: 0,
        is_virtual_country: ShippingDestination::Destinations::VIRTUAL_COUNTRY_CODES.include?(country_code)
      )
    end
    on.save!
    on.reload
  end

  describe "validation" do
    it "accepts a concrete country" do
      expect(product.shipping_exclusions.build(country_code: "US")).to be_valid
    end

    it "rejects regions, ELSEWHERE and unknown codes" do
      ["EUROPE", "ASIA", "NORTH AMERICA", "ELSEWHERE", "XX"].each do |country_code|
        expect(product.shipping_exclusions.build(country_code:)).not_to be_valid
      end
    end

    it "rejects the same country twice on one product but allows it on another product" do
      product.shipping_exclusions.create!(country_code: "US")

      expect(product.shipping_exclusions.build(country_code: "US")).not_to be_valid
      expect(create(:physical_product).shipping_exclusions.build(country_code: "US")).to be_valid
    end
  end

  describe "#save_shipping_exclusions!" do
    it "replaces the whole list" do
      product.save_shipping_exclusions!(%w[US CA])
      expect(product.reload.shipping_excluded_country_codes).to eq(%w[CA US])

      product.save_shipping_exclusions!(["CA"])
      expect(product.reload.shipping_excluded_country_codes).to eq(["CA"])

      product.save_shipping_exclusions!([])
      expect(product.reload.shipping_excluded_country_codes).to eq([])
    end

    it "ignores blanks and duplicates" do
      product.save_shipping_exclusions!(["US", "", nil, "US"])

      expect(product.reload.shipping_excluded_country_codes).to eq(["US"])
    end

    it "refuses a code that cannot be excluded" do
      expect do
        product.save_shipping_exclusions!(["ELSEWHERE"])
      end.to raise_error(Link::LinkInvalid, /cannot be excluded from shipping/)
    end

    it "refuses to exclude every country the product ships to" do
      set_destinations("US")

      expect do
        product.save_shipping_exclusions!(["US"])
      end.to raise_error(Link::LinkInvalid, /shippable to at least one destination/)

      expect(product.reload.shipping_excluded_country_codes).to eq([])
    end

    it "allows excluding a country while another one remains shippable" do
      set_destinations("US", "CA")

      product.save_shipping_exclusions!(["CA"])

      expect(product.reload.shippable_country_codes).to eq(["US"])
    end
  end

  describe "#publish!" do
    it "refuses to publish a draft whose only destination is excluded" do
      draft = create(:physical_product)
      set_destinations("US", on: draft)
      draft.shipping_exclusions.create!(country_code: "US")
      draft.update!(draft: true)

      expect do
        draft.reload.publish!
      end.to raise_error(Link::LinkInvalid, /shippable to at least one destination/)
    end
  end

  describe "#excludes_shipping_to?" do
    it "is true only for an excluded country" do
      product.shipping_exclusions.create!(country_code: "US")

      expect(product.excludes_shipping_to?("US")).to be true
      expect(product.excludes_shipping_to?("CA")).to be false
      expect(product.excludes_shipping_to?(nil)).to be false
    end
  end

  describe "#shippable_country_codes" do
    it "subtracts exclusions from the coverage a catch-all destination provides" do
      set_destinations(ShippingDestination::Destinations::EUROPE, ShippingDestination::Destinations::ELSEWHERE)
      product.shipping_exclusions.create!(country_code: "US")
      product.shipping_exclusions.create!(country_code: "CA")

      shippable = product.reload.shippable_country_codes

      expect(shippable).to include("DE", "GB")
      expect(shippable).not_to include("US", "CA")
    end

    it "leaves coverage untouched when nothing is excluded" do
      set_destinations("DE")

      expect(product.reload.shippable_country_codes).to eq(["DE"])
    end

    it "is empty for a digital product" do
      expect(create(:product).shippable_country_codes).to eq([])
    end
  end

  describe "ShippingDestination.for_product_and_country_code" do
    before do
      set_destinations(ShippingDestination::Destinations::ELSEWHERE)
    end

    it "returns nil for an excluded country even though ELSEWHERE covers it" do
      product.shipping_exclusions.create!(country_code: "US")

      expect(ShippingDestination.for_product_and_country_code(product: product.reload, country_code: "US")).to be_nil
      expect(ShippingDestination.for_product_and_country_code(product:, country_code: "CA")).to be_present
    end

    it "returns nil for an excluded country inside a covered virtual region" do
      set_destinations(ShippingDestination::Destinations::NORTH_AMERICA)
      product.shipping_exclusions.create!(country_code: "US")

      expect(ShippingDestination.for_product_and_country_code(product: product.reload, country_code: "US")).to be_nil
      expect(ShippingDestination.for_product_and_country_code(product:, country_code: "CA")).to be_present
    end

    it "honours an exclusion even when the product ships only that country" do
      set_destinations("US")
      product.shipping_exclusions.create!(country_code: "US")

      expect(ShippingDestination.for_product_and_country_code(product: product.reload, country_code: "US")).to be_nil
    end
  end

  describe "ProductDuplicatorService" do
    it "copies the exclusion list to the duplicate" do
      product.shipping_exclusions.create!(country_code: "US")

      duplicate = ProductDuplicatorService.new(product.id).duplicate

      expect(duplicate.reload.shipping_excluded_country_codes).to eq(["US"])
    end
  end
end
