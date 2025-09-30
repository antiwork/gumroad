# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Inertia Analytics Page", type: :system, js: true do
  let(:seller) { create(:user) }

  before do
    sign_in seller
    allow_any_instance_of(AnalyticsPresenter).to receive(:page_props).and_return({
      products: [
        { id: "prod_123", alive: true, unique_permalink: "test-product-1", name: "Test Product 1" },
        { id: "prod_456", alive: true, unique_permalink: "test-product-2", name: "Test Product 2" }
      ],
      country_codes: { "United States" => "US", "Canada" => "CA", "United Kingdom" => "GB" },
      state_names: ["California", "New York", "Texas", "Florida"]
    })
  end

  describe "Analytics page" do
    before do
      visit analytics_path
    end

    it "renders the analytics dashboard with proper content" do
      expect(page).to have_content("Analytics", wait: 10)
      expect(page).to have_content("Sales", wait: 10)
      expect(page).not_to have_content("Error")
    end

    it "displays analytics tabs and navigation" do
      expect(page).to have_css("[role='tablist']", wait: 10)
      expect(page).to have_css("[role='tab']", wait: 10)
      expect(page).to have_content("Sales", wait: 10)
    end

    it "shows analytics content area" do
      expect(page).to have_css("main", wait: 10)
      expect(page).to have_content("Sales", wait: 10)
      expect(page).to have_content("Views", wait: 10)
      expect(page).not_to have_content("Loading...", wait: 5)
    end

    it "displays product selection interface when user has products" do
      expect(page).to have_content("Select products...", wait: 10)
      expect(page).to have_css("select, [role='combobox']", wait: 10)
    end

    it "shows analytics data visualization elements" do
      expect(page).to have_content("Total", wait: 10)
      expect(page).to have_content("$0", wait: 10)
      expect(page).to have_content("Referrer", wait: 10)
      expect(page).to have_content("Locations", wait: 10)
    end

    it "handles analytics data loading and display" do
      expect(page).to have_content("Analytics", wait: 10)
      expect(page).not_to have_content("Loading...", wait: 5)
      expect(page).to have_css("main", wait: 10)
    end
  end
end
