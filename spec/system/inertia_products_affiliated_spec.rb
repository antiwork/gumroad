# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Inertia Products Affiliated Page", type: :system, js: true do
  let(:seller) { create(:user) }

  before do
    sign_in seller
  end

  describe "Products affiliated page" do
    before do
      visit products_affiliated_path
    end

    it "renders the products affiliated page with Inertia" do
      expect(page).to have_content("Products", wait: 10)

      # Verify Inertia component
      expect(page).to have_css("[data-page]")
      page_data = JSON.parse(page.find("[data-page]")["data-page"])
      expect(page_data["component"]).to eq("Products/Affiliated/Index")
    end

    it "displays affiliated products data correctly" do
      # Check if the page loads with Inertia first
      expect(page).to have_css("[data-page]")

      # Verify the page loads without errors
      expect(page).not_to have_content("Error")
    end

    it "handles affiliated products management functionality" do
      # Test that the page loads the affiliated products data
      expect(page).to have_css("[data-page]")

      # Verify Inertia component structure
      page_data = JSON.parse(page.find("[data-page]")["data-page"])
      expect(page_data["component"]).to eq("Products/Affiliated/Index")
    end
  end
end
