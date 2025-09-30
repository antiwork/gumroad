# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Inertia Reviews Page", type: :system, js: true do
  let(:seller) { create(:user) }

  before do
    sign_in seller
    Feature.activate(:reviews_page)

    @product = create(:product, user: seller, name: "Review Product")
    @review = create(:product_review, link: @product, rating: 5)
  end

  describe "Reviews page" do
    it "renders and displays reviews page with proper content" do
      visit reviews_path

      expect(page).to have_content("Reviews", wait: 10)

      expect(page).to have_content("You haven't bought anything... yet!", wait: 10)
      expect(page).not_to have_content("Error")

      expect(page).to have_css("main", wait: 10)
    end

    it "displays review interface elements" do
      visit reviews_path

      expect(page).to have_content("Reviews", wait: 10)

      expect(page).to have_css("main", wait: 10)
      expect(page).not_to have_content("Loading...", wait: 5)
    end

    it "shows reviews navigation and layout" do
      visit reviews_path

      expect(page).to have_content("Reviews", wait: 10)
      expect(page).to have_css("main", wait: 10)
      expect(page).to have_css("nav, .navigation, [role='navigation']", wait: 10)
    end

    it "displays reviews data sections" do
      visit reviews_path

      expect(page).to have_content("Reviews", wait: 10)
      expect(page).to have_css("main", wait: 10)
      expect(page).not_to have_content("Loading...", wait: 5)
    end
  end
end
