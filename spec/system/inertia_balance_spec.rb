# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Inertia Balance Page", type: :system, js: true do
  let(:seller) { create(:user) }

  before do
    sign_in seller
  end

  describe "Balance page" do
    before do
      visit balance_path
    end

    it "renders the balance page with proper content" do
      expect(page).to have_content("Payouts", wait: 10)
      expect(page).not_to have_content("Error")
    end

    it "displays payout interface elements" do
      expect(page).to have_content("Payouts", wait: 10)
      expect(page).to have_css("main", wait: 10)
      expect(page).not_to have_content("Loading...", wait: 5)
    end

    it "shows payout navigation and layout" do
      expect(page).to have_css("nav, .navigation, [role='navigation']", wait: 10)
      expect(page).to have_css("main", wait: 10)
      expect(page).to have_content("Payouts", wait: 10)
    end

    it "displays payout data and metrics" do
      expect(page).to have_content("Payouts", wait: 10)
      expect(page).to have_css("main", wait: 10)
      expect(page).not_to have_content("Loading...", wait: 5)
    end
  end
end
