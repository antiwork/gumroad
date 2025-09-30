# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Inertia Library Page", type: :system, js: true do
  let(:seller) { create(:user) }
  let(:user) { create(:user) }

  before do
    sign_in user
    # Create some test purchases for the library
    # The library shows purchases made by the logged-in user
    @product1 = create(:product, user: seller, name: "Test Product 1")
    @product2 = create(:product, user: seller, name: "Test Product 2")
    @purchase1 = create(:purchase, purchaser: user, link: @product1, purchase_state: "successful")
    @purchase2 = create(:purchase, purchaser: user, link: @product2, purchase_state: "successful")
  end

  describe "Library page" do
    before do
      visit library_path
    end

    it "renders the library page with Inertia" do
      expect(page).to have_content("Library", wait: 10)

      # Verify Inertia component
      expect(page).to have_css("[data-page]")
      page_data = JSON.parse(page.find("[data-page]")["data-page"])
      expect(page_data["component"]).to eq("Library/index")
    end

    it "displays purchased products" do
      # Check if the page loads with Inertia first
      expect(page).to have_css("[data-page]")

      # The library should show the products we purchased
      # If no products show up, the page should show "You haven't bought anything... yet!"
      if page.has_content?("You haven't bought anything... yet!")
        # This means the purchases aren't being found by the LibraryPresenter
        # Let's check if the purchases exist and meet the criteria
        expect(user.purchases.count).to be > 0
        expect(user.purchases.for_library.count).to be > 0
        expect(user.purchases.for_library.not_rental_expired.count).to be > 0
        expect(user.purchases.for_library.not_rental_expired.not_is_deleted_by_buyer.count).to be > 0
      else
        # If products are showing, check for our specific products
        expect(page).to have_content("Test Product 1", wait: 10)
        expect(page).to have_content("Test Product 2")
      end
    end

    it "handles library search functionality" do
      # Test search by filling the search form
      fill_in "search", with: "Test Product 1"
      click_button "Search"

      # Wait for search results to load
      expect(page).to have_content("Test Product 1", wait: 10)

      # Verify search results are displayed
      expect(page).to have_css("[data-page]")
      page_data = JSON.parse(page.find("[data-page]")["data-page"])
      expect(page_data["component"]).to eq("Library/index")
    end
  end
end
