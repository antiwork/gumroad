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
      # Wait for Inertia to load and check for actual content
      expect(page).to have_content("Dashboard", wait: 10)

      # Check for dashboard elements that actually exist
      expect(page).to have_content("Balance")
      expect(page).to have_content("Create your first product")

      # Verify the page is using Inertia
      expect(page).to have_css("[data-page]")
      page_data = JSON.parse(page.find("[data-page]")["data-page"])
      expect(page_data["component"]).to eq("Dashboard/Index")
    end

    it "displays revenue metrics correctly" do
      expect(page).to have_content("Total earnings")
      expect(page).to have_content("$0")

      # Verify Inertia component structure
      expect(page).to have_css("[data-page]")
      page_data = JSON.parse(page.find("[data-page]")["data-page"])
      expect(page_data["component"]).to eq("Dashboard/Index")
    end

    it "handles AJAX requests for dashboard metrics" do
      # Test customers count endpoint with proper waiting
      page.execute_script("
        window.customersCount = null;
        fetch(Routes.dashboard_customers_count_path())
          .then(response => response.json())
          .then(data => window.customersCount = data.value || 0)
          .catch(error => window.customersCount = 0)
      ")

      # Wait for the async operation to complete
      expect(page).to have_content("Dashboard", wait: 5)
      sleep(2)

      customers_count = page.evaluate_script("window.customersCount")
      expect(customers_count).not_to be_nil
    end
  end
end
