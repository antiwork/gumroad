# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Inertia Checkout Page", type: :system, js: true do
  let(:user) { create(:user) }

  before do
    sign_in user
  end

  describe "Checkout page" do
    before do
      visit checkout_index_path
    end

    it "renders the checkout page with proper content" do
      # Test actual HTML content that users would see
      expect(page).to have_content("Analytics", wait: 10)

      # Verify the page loads without errors
      expect(page).not_to have_content("Error")
    end

    it "displays checkout interface elements" do
      # Test that the checkout interface is rendered
      expect(page).to have_content("Analytics", wait: 10)

      # Check for common checkout page elements
      expect(page).to have_css("main", wait: 10)
      expect(page).not_to have_content("Loading...", wait: 5)
    end

    it "shows checkout navigation and layout" do
      # Test that the main layout elements are present
      expect(page).to have_content("Analytics", wait: 10)
      expect(page).to have_css("main", wait: 10)
    end
  end
end
