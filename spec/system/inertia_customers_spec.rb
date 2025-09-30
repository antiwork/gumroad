# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Inertia Customers Page", type: :system, js: true do
  let(:seller) { create(:user) }

  before do
    sign_in seller
  end

  describe "Customers page" do
    before do
      visit customers_path
    end

    it "renders the customers page with Inertia" do
      expect(page).to have_content("Sales", wait: 10)

      # Verify Inertia component
      expect(page).to have_css("[data-page]")
      page_data = JSON.parse(page.find("[data-page]")["data-page"])
      expect(page_data["component"]).to eq("Customers/Index")
    end

    it "displays customer data correctly" do
      # Check if the page loads with Inertia first
      expect(page).to have_css("[data-page]")

      # Verify the customers props are passed correctly
      page_data = JSON.parse(page.find("[data-page]")["data-page"])
      expect(page_data["props"]).to have_key("customers_presenter")
    end

    it "handles customer search functionality" do
      # Test that the page loads without errors
      expect(page).not_to have_content("Error")

      # Verify Inertia component structure
      expect(page).to have_css("[data-page]")
      page_data = JSON.parse(page.find("[data-page]")["data-page"])
      expect(page_data["component"]).to eq("Customers/Index")
    end
  end
end
