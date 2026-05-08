# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe("Product Edit Price Checker Scenario", type: :system, js: true) do
  let(:seller) { create(:named_seller) }
  let(:films_taxonomy) { Taxonomy.find_by(slug: "films") }
  let(:matching_attrs) do
    {
      name: "Documentary about widgets",
      description: "A long documentary description about widgets for the relevance filter to match comparable products.",
      taxonomy: films_taxonomy,
      native_type: "digital",
    }
  end

  before :each do
    Flipper.enable(:price_checker)
    @product = create(:product, **matching_attrs, user: seller, price_cents: 1_000)
    allow_any_instance_of(Link).to receive(:recommendable?).and_return(true)
  end

  include_context "with switching account to user as admin for seller"

  context "with sufficient comparable products" do
    before do
      12.times do |i|
        create(:product, **matching_attrs, user: create(:user), price_cents: 800 + i * 100)
      end
      index_model_records(Link)
    end

    it "loads a price distribution when the seller clicks Check prices" do
      visit("/products/#{@product.unique_permalink}/edit")

      expect(page).to have_text("Price checker", wait: 15)
      expect(page).to have_button("Check prices")

      click_on "Check prices"

      expect(page).to have_text(/Based on \d+ digital products?/, wait: 15)
      expect(page).to have_no_button("Check prices")
    end
  end

  context "without sufficient comparable products" do
    before do
      index_model_records(Link)
    end

    it "shows the insufficient-data state when the seller clicks Check prices" do
      visit("/products/#{@product.unique_permalink}/edit")

      expect(page).to have_text("Price checker", wait: 15)
      expect(page).to have_button("Check prices")

      click_on "Check prices"

      expect(page).to have_text("Not enough comparable products yet", wait: 15)
      expect(page).to have_text("MATCH ACCURACY")
    end
  end

  context "with paid variants" do
    before do
      variant_category = create(:variant_category, link: @product, title: "Edition")
      create(:variant, variant_category:, name: "Premium", price_difference_cents: 500)

      12.times do |i|
        create(:product, **matching_attrs, user: create(:user), price_cents: 800 + i * 100)
      end
      index_model_records(Link)
    end

    it "renders the base price and the variant marker on the chart" do
      visit("/products/#{@product.unique_permalink}/edit")

      expect(page).to have_text("Price checker", wait: 15)

      click_on "Check prices"

      expect(page).to have_text(/Based on \d+ digital products?/, wait: 15)
      expect(page).to have_text("Base price")
      expect(page).to have_text("Premium")
    end
  end
end
