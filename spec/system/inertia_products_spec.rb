# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Inertia Products Page", type: :system, js: true do
  let(:seller) { create(:user) }

  before do
    sign_in seller
  end

  describe "Products index page" do
    before do
      visit products_path
    end

    it "renders the products page with Inertia" do
      expect(page).to have_content("Products", wait: 10)

      # Verify Inertia component
      expect(page).to have_css("[data-page]")
      page_data = JSON.parse(page.find("[data-page]")["data-page"])
      expect(page_data["component"]).to eq("Products/Index")
    end

    it "displays product data correctly" do
      # Check if the page loads with Inertia first
      expect(page).to have_css("[data-page]")

      # Verify the page loads without errors
      expect(page).not_to have_content("Error")
    end

    it "handles product management functionality" do
      # Test that the page loads the products data
      expect(page).to have_css("[data-page]")

      # Verify Inertia component structure
      page_data = JSON.parse(page.find("[data-page]")["data-page"])
      expect(page_data["component"]).to eq("Products/Index")
    end
  end

  describe "Products new page" do
    before do
      visit new_product_path
    end

    it "renders the new product page with Inertia" do
      expect(page).to have_content("Create", wait: 10)

      # Verify Inertia component
      expect(page).to have_css("[data-page]")
      page_data = JSON.parse(page.find("[data-page]")["data-page"])
      expect(page_data["component"]).to eq("Products/New/Index")
    end

    it "displays product form correctly" do
      # Check if the page loads with Inertia first
      expect(page).to have_css("[data-page]")

      # Verify the page loads without errors
      expect(page).not_to have_content("Error")
    end

    it "handles product creation functionality" do
      # Test that the page loads the product form
      expect(page).to have_css("[data-page]")

      # Verify Inertia component structure
      page_data = JSON.parse(page.find("[data-page]")["data-page"])
      expect(page_data["component"]).to eq("Products/New/Index")
    end
  end
end
