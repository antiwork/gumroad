# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe("Product Edit Price Checker Scenario", type: :system, js: true) do
  let(:seller) { create(:named_seller) }
  let(:films_taxonomy) { Taxonomy.find_or_create_by(slug: "films") }

  before :each do
    matching_attrs = {
      name: "Documentary about widgets",
      description: "A long documentary description about widgets for the relevance filter to match comparable products.",
      taxonomy: films_taxonomy,
      native_type: "digital",
    }

    @product = create(:product, **matching_attrs, user: seller, price_cents: 1_000)

    12.times do |i|
      create(:product, **matching_attrs, user: create(:user), price_cents: 800 + i * 100)
    end

    allow_any_instance_of(Link).to receive(:recommendable?).and_return(true)
    index_model_records(Link)
  end

  include_context "with switching account to user as admin for seller"

  it "loads a price distribution when the seller clicks Check prices" do
    visit("/products/#{@product.unique_permalink}/edit")

    expect(page).to have_text("Price checker", wait: 15)
    expect(page).to have_button("Check prices")

    click_on "Check prices"

    expect(page).to have_text(/Based on \d+ digital products?/, wait: 15)
    expect(page).to have_no_button("Check prices")
  end
end
