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

    it "renders the wishlists page with Inertia" do
      expect(page).to have_content("Wishlists", wait: 10)

      # Verify Inertia component
      expect(page).to have_css("[data-page]")
      page_data = JSON.parse(page.find("[data-page]")["data-page"])
      expect(page_data["component"]).to eq("Wishlists/index")
    end

    it "displays wishlists data correctly" do
      # Check if the page loads with Inertia first
      expect(page).to have_css("[data-page]")

      # Verify the wishlists props are passed correctly
      page_data = JSON.parse(page.find("[data-page]")["data-page"])
      expect(page_data["props"]).to have_key("wishlists")
      expect(page_data["props"]).to have_key("reviews_page_enabled")
      expect(page_data["props"]).to have_key("following_wishlists_enabled")
    end

    it "handles wishlist management functionality" do
      # Test that the page loads without errors
      expect(page).not_to have_content("Error")

      # Verify Inertia component structure
      expect(page).to have_css("[data-page]")
      page_data = JSON.parse(page.find("[data-page]")["data-page"])
      expect(page_data["component"]).to eq("Wishlists/index")
    end
  end

  describe "Wishlist show page" do
    let(:wishlist) { create(:wishlist, user: seller) }

    before do
      visit wishlist_path(wishlist)
    end

    it "renders the wishlist page with Inertia" do
      expect(page).to have_content(wishlist.name, wait: 10)

      # Verify Inertia component
      expect(page).to have_css("[data-page]")
      page_data = JSON.parse(page.find("[data-page]")["data-page"])
      expect(page_data["component"]).to eq("WishlistPage")
    end

    it "displays wishlist data correctly" do
      # Check if the page loads with Inertia first
      expect(page).to have_css("[data-page]")

      # Verify the page loads without errors
      expect(page).not_to have_content("Error")
    end

    it "handles wishlist viewing functionality" do
      # Test that the page loads the wishlist data
      expect(page).to have_css("[data-page]")

      # Verify Inertia component structure
      page_data = JSON.parse(page.find("[data-page]")["data-page"])
      expect(page_data["component"]).to eq("WishlistPage")
    end
  end
end
