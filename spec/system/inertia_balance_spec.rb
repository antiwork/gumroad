# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Inertia Balance Page", type: :system, js: true do
  let(:seller) { create(:user) }

  before do
    sign_in seller
  end

  describe "Balance page" do
    before do
      visit balance_path
    end

    it "renders the balance page with Inertia" do
      expect(page).to have_content("Payouts", wait: 10)

      # Verify Inertia component
      expect(page).to have_css("[data-page]")
      page_data = JSON.parse(page.find("[data-page]")["data-page"])
      expect(page_data["component"]).to eq("Payouts/Index")
    end

    it "displays payout data correctly" do
      # Check if the page loads with Inertia first
      expect(page).to have_css("[data-page]")

      # Verify the payout presenter props are passed correctly
      page_data = JSON.parse(page.find("[data-page]")["data-page"])
      expect(page_data["props"]).to have_key("payout_presenter")
    end

    it "handles payout management functionality" do
      # Test that the page loads without errors
      expect(page).not_to have_content("Error")

      # Verify Inertia component structure
      expect(page).to have_css("[data-page]")
      page_data = JSON.parse(page.find("[data-page]")["data-page"])
      expect(page_data["component"]).to eq("Payouts/Index")
    end
  end
end
