# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Inertia Checkout Upsells Page", type: :system, js: true do
  let(:seller) { create(:user) }

  before do
    sign_in seller
  end

  describe "Checkout upsells page" do
    before do
      visit checkout_upsells_path
    end

    it "renders the checkout upsells page with proper content" do
      expect(page).to have_content("Upsells", wait: 10)
      expect(page).to have_content("New upsell", wait: 10)

      expect(page).not_to have_content("Error")
    end

    it "displays upsells interface elements" do
      expect(page).to have_content("Upsells", wait: 10)

      expect(page).to have_css("main", wait: 10)
      expect(page).not_to have_content("Loading...", wait: 5)
    end

    it "shows upsells navigation and layout" do
      expect(page).to have_content("Upsells", wait: 10)
      expect(page).to have_css("main", wait: 10)
    end
  end
end
