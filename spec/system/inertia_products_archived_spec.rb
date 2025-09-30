# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Inertia Products Archived Page", type: :system, js: true do
  let(:seller) { create(:user) }

  before do
    sign_in seller
  end

  describe "Products archived page" do
    before do
      visit products_archived_index_path
    end

    it "renders the archived products page with proper content" do
      # Test actual HTML content that users would see
      expect(page).to have_content("Analytics", wait: 10)

      # Verify the page loads without errors
      expect(page).not_to have_content("Error")
    end

    it "displays archived products interface elements" do
      # Test that the archived products interface is rendered
      expect(page).to have_content("Analytics", wait: 10)

      # Check for common archived products page elements
      expect(page).to have_css("main", wait: 10)
      expect(page).not_to have_content("Loading...", wait: 5)
    end

    it "shows archived products navigation and layout" do
      # Test that the main layout elements are present
      expect(page).to have_content("Analytics", wait: 10)
      expect(page).to have_css("main", wait: 10)
    end
  end
end
