# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Inertia Reviews Page", type: :system, js: true do
  let(:seller) { create(:user) }

  before do
    sign_in seller
    # Activate the reviews_page feature flag
    Feature.activate(:reviews_page)

    # Create test reviews
    @product = create(:product, user: seller, name: "Review Product")
    @review = create(:product_review, link: @product, rating: 5)
  end

  describe "Reviews page" do
    it "renders and displays reviews page with proper content" do
      visit reviews_path

      # Test actual HTML content that users would see
      expect(page).to have_content("Reviews", wait: 10)

      # Test for specific review content as requested by EmCousin
      expect(page).to have_content("You haven't bought anything... yet!", wait: 10)
      expect(page).not_to have_content("Error")

      # Verify the page loads without errors
      expect(page).to have_css("main", wait: 10)
    end

    it "displays review interface elements" do
      visit reviews_path

      # Test that the review interface is rendered
      expect(page).to have_content("Reviews", wait: 10)

      # Check for common review page elements
      expect(page).to have_css("main", wait: 10)
      expect(page).not_to have_content("Loading...", wait: 5)
    end

    it "shows reviews navigation and layout" do
      visit reviews_path

      # Test that the main layout elements are present
      expect(page).to have_content("Reviews", wait: 10)
      expect(page).to have_css("main", wait: 10)
    end
  end
end
