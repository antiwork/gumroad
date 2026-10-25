# frozen_string_literal: true

require "spec_helper"

describe "Clearing bundle product search", type: :system, js: true do
  let(:seller) { create(:named_seller) }
  let!(:bundle) { create(:product, :bundle, user: seller) }

  before do
    create(:product, name: "Alpha product", user: seller)
    create(:product, name: "Beta product", user: seller)
    index_model_records(Link)
    login_as seller
    visit edit_bundle_content_path(bundle.external_id)
  end

  it "removes the old query and restores results without changing selected bundle products" do
    persisted_count = bundle.bundle_products.count
    within "[aria-label='Product selector']" do
      check "Beta product", unchecked: true
    end
    fill_in "Search products", with: "Alpha product"
    within "[aria-label='Product selector']" do
      expect(page).to have_field("Alpha product")
      expect(page).not_to have_field("Beta product")
    end
    fill_in "Search products", with: ""
    within "[aria-label='Product selector']" do
      expect(page).to have_field("Alpha product")
      expect(page).to have_checked_field("Beta product")
    end
    expect(URI.decode_www_form(URI.parse(page.current_url).query.to_s).to_h["query"]).to be_nil
    within("[aria-label='Bundle products']") { expect(page).to have_text("Beta product") }
    expect(bundle.bundle_products.count).to eq(persisted_count)
  end

  it "recovers from no results and supports searching and clearing again" do
    fill_in "Search products", with: "No such product"
    within("[aria-label='Product selector']") { expect(page).to have_text("No products found") }
    fill_in "Search products", with: ""
    within "[aria-label='Product selector']" do
      expect(page).to have_field("Alpha product")
      expect(page).to have_field("Beta product")
    end
    fill_in "Search products", with: "Beta product"
    within "[aria-label='Product selector']" do
      expect(page).to have_field("Beta product")
      expect(page).not_to have_field("Alpha product")
    end
    fill_in "Search products", with: ""
    within "[aria-label='Product selector']" do
      expect(page).to have_field("Alpha product")
      expect(page).to have_field("Beta product")
    end
  end
end
