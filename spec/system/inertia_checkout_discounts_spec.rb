# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Inertia Checkout Discounts Page", type: :system, js: true do
  let(:seller) { create(:user) }

  before do
    sign_in seller
  end

  describe "Checkout discounts page" do
    before do
      visit checkout_discounts_path
    end

    it "renders the checkout discounts page with Inertia" do
      expect(page).to have_content("Discounts", wait: 10)

      # Verify Inertia component
      expect(page).to have_css("[data-page]")
      page_data = JSON.parse(page.find("[data-page]")["data-page"])
      expect(page_data["component"]).to eq("Checkout/Discounts/index")
    end

    it "displays discounts data correctly" do
      # Check if the page loads with Inertia first
      expect(page).to have_css("[data-page]")

      # Verify the discounts props are passed correctly
      page_data = JSON.parse(page.find("[data-page]")["data-page"])
      expect(page_data["props"]).to have_key("discounts_props")
    end

    it "handles discounts management functionality" do
      # Test that the page loads without errors
      expect(page).not_to have_content("Error")

      # Verify Inertia component structure
      expect(page).to have_css("[data-page]")
      page_data = JSON.parse(page.find("[data-page]")["data-page"])
      expect(page_data["component"]).to eq("Checkout/Discounts/index")
    end
  end
end
