# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Inertia Checkout Page", type: :system, js: true do
  let(:user) { create(:user) }

  before do
    sign_in user
  end

  describe "Checkout page" do
    before do
      visit checkout_path
    end

    it "renders the checkout page with Inertia" do
      expect(page).to have_content("Checkout", wait: 10)

      # Verify Inertia component
      expect(page).to have_css("[data-page]")
      page_data = JSON.parse(page.find("[data-page]")["data-page"])
      expect(page_data["component"]).to eq("Checkout/Index")
    end

    it "displays checkout data correctly" do
      # Check if the page loads with Inertia first
      expect(page).to have_css("[data-page]")

      # Verify the checkout props are passed correctly
      page_data = JSON.parse(page.find("[data-page]")["data-page"])
      expect(page_data["props"]).to have_key("checkout_props")
    end

    it "handles checkout functionality" do
      # Test that the page loads without errors
      expect(page).not_to have_content("Error")

      # Verify Inertia component structure
      expect(page).to have_css("[data-page]")
      page_data = JSON.parse(page.find("[data-page]")["data-page"])
      expect(page_data["component"]).to eq("Checkout/Index")
    end
  end
end
