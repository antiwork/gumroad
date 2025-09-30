# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Inertia Products Collabs Page", type: :system, js: true do
  let(:seller) { create(:user) }

  before do
    sign_in seller
  end

  describe "Products collabs page" do
    before do
      visit products_collabs_path
    end

    it "renders the products collabs page with proper content" do
      expect(page).to have_content("Products", wait: 10)
      expect(page).to have_content("Create your first collab!", wait: 10)

      expect(page).not_to have_content("Error")
    end

    it "displays collaboration interface elements" do
      expect(page).to have_content("Analytics", wait: 10)

      expect(page).to have_css("main", wait: 10)
      expect(page).not_to have_content("Loading...", wait: 5)
    end

    it "shows products navigation and layout" do
      expect(page).to have_content("Products", wait: 10)
      expect(page).to have_css("main", wait: 10)
    end
  end
end
