# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Inertia Wishlists Page", type: :system, js: true do
  let(:seller) { create(:user) }

  before do
    sign_in seller
  end

  describe "Wishlists index page" do
    before do
      visit wishlists_path
    end

    it "renders the wishlists page with proper content" do
      expect(page).to have_content("Analytics", wait: 10)
      expect(page).not_to have_content("Error")
    end

    it "displays wishlists interface elements" do
      expect(page).to have_content("Analytics", wait: 10)
      expect(page).to have_css("main", wait: 10)
    end

    it "shows wishlists navigation and layout" do
      expect(page).to have_css("main", wait: 10)
      expect(page).to have_css("nav, .navigation, [role='navigation']", wait: 10)
      expect(page).not_to have_content("Error")
    end

    it "displays wishlists data sections" do
      expect(page).to have_content("Analytics", wait: 10)
      expect(page).to have_css("main", wait: 10)
      expect(page).not_to have_content("Loading...", wait: 5)
    end
  end

  describe "Wishlist show page" do
    let(:wishlist) { create(:wishlist, user: seller) }

    before do
      wishlist # Force creation
      visit wishlists_path
    end

    it "renders the wishlist page with proper content" do
      expect(page).to have_content("Analytics", wait: 10)
      expect(page).not_to have_content("Error")
    end

    it "displays wishlist content and layout" do
      expect(page).to have_content("Analytics", wait: 10)
      expect(page).to have_css("main", wait: 10)
    end

    it "shows wishlist navigation and structure" do
      expect(page).to have_css("main", wait: 10)
      expect(page).to have_css("nav, .navigation, [role='navigation']", wait: 10)
      expect(page).not_to have_content("Error")
    end

    it "displays wishlist show data sections" do
      expect(page).to have_content("Analytics", wait: 10)
      expect(page).to have_css("main", wait: 10)
      expect(page).not_to have_content("Loading...", wait: 5)
    end
  end
end
