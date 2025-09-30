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

    it "renders the customers page with proper content" do
      # Test actual HTML content that users would see
      expect(page).to have_content("Sales", wait: 10)
      expect(page).to have_content("Manage all of your sales in one place", wait: 10)

      # Verify the page loads without errors
      expect(page).not_to have_content("Error")
    end

    it "displays customer interface elements" do
      # Test that the customer interface is rendered
      expect(page).to have_content("Sales", wait: 10)

      # Check for common customer page elements
      expect(page).to have_css("main", wait: 10)
      expect(page).not_to have_content("Loading...", wait: 5)
    end

    it "shows customer navigation and layout" do
      # Test that the main layout elements are present
      expect(page).to have_content("Sales", wait: 10)
      expect(page).to have_css("main", wait: 10)
    end
  end
end
