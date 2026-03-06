# frozen_string_literal: true

require "spec_helper"

describe("Product Edit (Inertia) Scenario", type: :system, js: true) do
  include ProductEditPageHelpers

  let(:seller) { create(:named_seller) }
  let!(:product) { create(:product, user: seller) }

  before :each do
    login_as(seller)
  end

  it "loads the product edit page via Inertia" do
    visit edit_link_path(product.unique_permalink)
    expect(page).to have_text(product.name)
  end

  it "navigates between tabs" do
    visit edit_link_path(product.unique_permalink)
    expect(page).to have_text(product.name)

    click_on "Content"
    expect(page).to have_current_path(%r{/edit/content})

    click_on "Receipt"
    expect(page).to have_current_path(%r{/edit/receipt})

    click_on "Product"
    expect(page).to have_current_path(%r{/edit\z})
  end

  it "loads sub-routes directly (browser refresh)" do
    visit "/products/#{product.unique_permalink}/edit/content"
    expect(page).to have_current_path(%r{/edit/content})
    expect(page).to have_text(product.name)

    visit "/products/#{product.unique_permalink}/edit/receipt"
    expect(page).to have_current_path(%r{/edit/receipt})
    expect(page).to have_text(product.name)
  end

  it "saves changes" do
    visit edit_link_path(product.unique_permalink)
    expect(page).to have_text(product.name)
    save_change
  end
end
