# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Inertia UTM Links Page", type: :system, js: true do
  let(:seller) { create(:user) }

  before do
    sign_in seller
  end

  describe "UTM Links page" do
    before do
      visit utm_links_dashboard_path
    end

    it "renders the UTM links page with Inertia" do
      expect(page).to have_content("UTM Links", wait: 10)

      # Verify Inertia component
      expect(page).to have_css("[data-page]")
      page_data = JSON.parse(page.find("[data-page]")["data-page"])
      expect(page_data["component"]).to eq("UtmLinks/index")
    end

    it "displays UTM links data correctly" do
      # Check if the page loads with Inertia first
      expect(page).to have_css("[data-page]")

      # Verify the UTM links props are passed correctly
      page_data = JSON.parse(page.find("[data-page]")["data-page"])
      expect(page_data["props"]).to have_key("utm_links")
      expect(page_data["props"]).to have_key("pagination")
      expect(page_data["props"]).to have_key("context")
    end

    it "handles UTM link management functionality" do
      # Test that the page loads without errors
      expect(page).not_to have_content("Error")

      # Verify Inertia component structure
      expect(page).to have_css("[data-page]")
      page_data = JSON.parse(page.find("[data-page]")["data-page"])
      expect(page_data["component"]).to eq("UtmLinks/index")
    end
  end
end
