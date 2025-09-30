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
    it "renders and displays reviews page with Inertia" do
      visit reviews_path

      # Verify page content and Inertia component
      expect(page).to have_content("Reviews", wait: 10)
      expect(page).not_to have_content("Error")

      # Verify Inertia component
      expect(page).to have_css("[data-page]")
      page_data = JSON.parse(page.find("[data-page]")["data-page"])
      expect(page_data["component"]).to eq("Reviews/Index")

      # Verify the reviews props are passed correctly
      expect(page_data["props"]).to have_key("reviews_props")
    end
  end
end
