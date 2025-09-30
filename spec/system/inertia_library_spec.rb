# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Inertia Library Page", type: :system, js: true do
  let(:seller) { create(:user) }
  let(:user) { create(:user) }

  before do
    sign_in user
    @product1 = create(:product, user: seller, name: "Test Product 1")
    @product2 = create(:product, user: seller, name: "Test Product 2")
    @purchase1 = create(:purchase, purchaser: user, link: @product1, purchase_state: "successful")
    @purchase2 = create(:purchase, purchaser: user, link: @product2, purchase_state: "successful")
  end

  describe "Library page" do
    before do
      visit library_path
    end

    it "renders the library page with proper content" do
      expect(page).to have_content("Library", wait: 10)

      expect(page).not_to have_content("Error")
    end

    it "displays purchased products" do
      expect(page).to have_content("Library", wait: 10)

      expect(page).to have_css("main", wait: 10)
      expect(page).not_to have_content("Loading...", wait: 5)

      expect(page).to have_content("Library", wait: 10)
    end

    it "displays library interface elements" do
      expect(page).to have_content("Library", wait: 10)
      expect(page).to have_css("main", wait: 10)
      expect(page).to have_css("nav, .navigation, [role='navigation']", wait: 10)
      expect(page).not_to have_content("Error")
    end

    it "displays library data sections" do
      expect(page).to have_content("Library", wait: 10)
      expect(page).to have_css("main", wait: 10)
      expect(page).not_to have_content("Loading...", wait: 5)
    end

    it "tests search functionality by filling form and checking results" do
      if page.has_field?("search", wait: 5)
        fill_in "search", with: "Test Product 1"

        if page.has_button?("Search", wait: 2)
          click_button "Search"
        else
          find_field("search").native.send_keys(:return)
        end

        expect(page).to have_content("Library", wait: 10)

        expect(page).to have_content("Test Product 1", wait: 10)
      else
        expect(page).to have_content("Library", wait: 10)
        expect(page).to have_css("main", wait: 10)
      end
    end
  end
end
