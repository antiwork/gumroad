# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Inertia Products Affiliated Page", type: :system, js: true do
  let(:seller) { create(:user) }

  before do
    sign_in seller
  end

  describe "Products affiliated page" do
    before do
      visit products_affiliated_index_path
    end

    it "renders the products affiliated page with proper content" do
      expect(page).to have_content("Products", wait: 10)

      expect(page).not_to have_content("Error")
    end

    it "displays affiliated products interface elements" do
      expect(page).to have_content("Products", wait: 10)

      expect(page).to have_css("main", wait: 10)
      expect(page).not_to have_content("Loading...", wait: 5)
    end

    it "shows affiliated products navigation and layout" do
      expect(page).to have_content("Products", wait: 10)
      expect(page).to have_css("main", wait: 10)
    end
  end
end
