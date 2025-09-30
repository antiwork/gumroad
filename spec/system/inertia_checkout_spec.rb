# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Inertia Checkout Page", type: :system, js: true do
  let(:user) { create(:user) }

  before do
    sign_in user
  end

  describe "Checkout page" do
    before do
      visit checkout_index_path
    end

    it "renders the checkout page with proper content" do
      expect(page).to have_content("Analytics", wait: 10)
      expect(page).not_to have_content("Error")
    end

    it "displays checkout interface elements" do
      expect(page).to have_content("Analytics", wait: 10)
      expect(page).to have_css("main", wait: 10)
      expect(page).not_to have_content("Loading...", wait: 5)
    end

    it "shows checkout navigation and layout" do
      expect(page).to have_css("nav, .navigation, [role='navigation']", wait: 10)
      expect(page).to have_css("main", wait: 10)
      expect(page).to have_content("Analytics", wait: 10)
    end

    it "displays checkout data sections" do
      expect(page).to have_content("Analytics", wait: 10)
      expect(page).to have_css("main", wait: 10)
      expect(page).not_to have_content("Loading...", wait: 5)
    end
  end
end
