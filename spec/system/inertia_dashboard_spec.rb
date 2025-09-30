# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Inertia Dashboard Page", type: :system, js: true do
  let(:seller) { create(:user) }

  before do
    sign_in seller
  end

  describe "Dashboard page" do
    before do
      visit dashboard_path
    end

    it "renders the dashboard with key metrics" do
      expect(page).to have_content("Dashboard", wait: 10)
      expect(page).to have_content("Balance")
      expect(page).to have_content("Create your first product")
      expect(page).not_to have_content("Error")
    end

    it "displays revenue metrics correctly" do
      expect(page).to have_content("Total earnings")
      expect(page).to have_content("$0")
      expect(page).not_to have_content("Error")
    end

    it "handles AJAX requests for dashboard metrics" do
      expect(page).to have_content("Dashboard", wait: 10)
      expect(page).to have_content("Balance", wait: 10)
      expect(page).to have_css("main", wait: 10)
      expect(page).not_to have_content("Error")
    end
  end
end
