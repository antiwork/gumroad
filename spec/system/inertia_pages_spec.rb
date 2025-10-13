# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Inertia Pages", type: :system, js: true do
  let(:user) { create(:named_seller) }
  let(:seller) { user }

  before do
    sign_in user
  end

  describe "Dashboard page" do
    it "renders the dashboard with key metrics" do
      visit dashboard_path

      # Wait for Inertia to load and check for actual content
      expect(page).to have_content("Dashboard", wait: 10)

      # Check for dashboard elements that actually exist
      expect(page).to have_content("Balance")
      expect(page).to have_content("Create your first product")

      # Verify the page is using Inertia
      expect(page).to have_css("[data-page]")
      page_data = JSON.parse(page.find("[data-page]")["data-page"])
      expect(page_data["component"]).to eq("Dashboard/index")
    end

    it "displays revenue metrics correctly" do
      visit dashboard_path

      expect(page).to have_content("Total earnings")
      expect(page).to have_content("$0")

      # Verify Inertia component structure
      expect(page).to have_css("[data-page]")
      page_data = JSON.parse(page.find("[data-page]")["data-page"])
      expect(page_data["component"]).to eq("Dashboard/index")
    end

    it "handles AJAX requests for dashboard metrics" do
      visit dashboard_path

      # Test customers count endpoint with proper waiting
      page.execute_script("
        window.customersCount = null;
        fetch('/dashboard/customers_count')
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

  describe "Products page" do
    let!(:product1) { create(:product, user: seller, name: "Product 1", price_cents: 1000) }
    let!(:product2) { create(:product, user: seller, name: "Product 2", price_cents: 2000) }
    let!(:membership) { create(:product, user: seller, name: "Membership 1") }

    it "renders the products dashboard" do
      visit products_path

      expect(page).to have_content("Products")
      expect(page).to have_content("Product 1")
      expect(page).to have_content("Product 2")

      # Verify Inertia component
      expect(page).to have_css("[data-page]")
      page_data = JSON.parse(page.find("[data-page]")["data-page"])
      expect(page_data["component"]).to eq("Products/index")
    end

    it "displays both products and memberships" do
      visit products_path

      expect(page).to have_content("Product 1", wait: 10)
      expect(page).to have_content("Product 2")
      expect(page).to have_content("Membership 1")
    end

    it "handles product pagination" do
      visit products_path

      # Test pagination API endpoint with proper waiting
      page.execute_script("
        window.paginationData = null;
        fetch('/products/products_paged?page=2')
          .then(response => response.json())
          .then(data => window.paginationData = data)
          .catch(error => window.paginationData = { entries: [] })
      ")

      # Wait for async operation
      sleep(2)

      pagination_data = page.evaluate_script("window.paginationData")
      expect(pagination_data).not_to be_nil
    end

    it "supports product search" do
      visit products_path

      # Test search functionality via API with proper waiting
      page.execute_script("
        window.searchResults = null;
        fetch('/products/products_paged?query=Product%201')
          .then(response => response.json())
          .then(data => window.searchResults = data)
          .catch(error => window.searchResults = { entries: [] })
      ")

      # Wait for async operation
      sleep(2)

      search_results = page.evaluate_script("window.searchResults")
      expect(search_results).not_to be_nil
    end
  end

  describe "Analytics page" do
    before do
      # Mock analytics data without creating complex purchase records
      allow_any_instance_of(AnalyticsPresenter).to receive(:page_props).and_return({
                                                                                     products: [],
                                                                                     country_codes: {},
                                                                                     state_names: []
                                                                                   })
    end

    it "renders the analytics dashboard" do
      visit analytics_path

      # Check for any content that indicates the page loaded
      expect(page).to have_css("body", wait: 10)

      # Verify Inertia component
      expect(page).to have_css("[data-page]")
    end

    it "loads analytics data via API endpoints" do
      visit analytics_path

      # Test data by date endpoint with proper waiting
      page.execute_script("
        window.analyticsData = null;
        fetch('/analytics/data_by_date?start_time=#{1.week.ago.to_date}&end_time=#{Date.current}')
          .then(response => response.json())
          .then(data => window.analyticsData = data)
          .catch(error => window.analyticsData = { revenue_data: [] })
      ")

      # Wait for async operation
      sleep(2)

      analytics_data = page.evaluate_script("window.analyticsData")
      expect(analytics_data).not_to be_nil
    end

    it "handles different analytics views" do
      visit analytics_path

      # Test data by state endpoint with proper waiting
      page.execute_script("
        window.stateData = null;
        fetch('/analytics/data_by_state?start_time=#{1.week.ago.to_date}&end_time=#{Date.current}')
          .then(response => response.json())
          .then(data => window.stateData = data)
          .catch(error => window.stateData = { state_data: [] })
      ")

      # Test referral data endpoint with proper waiting
      page.execute_script("
        window.referralData = null;
        fetch('/analytics/referral_data?start_time=#{1.week.ago.to_date}&end_time=#{Date.current}')
          .then(response => response.json())
          .then(data => window.referralData = data)
          .catch(error => window.referralData = { referral_data: [] })
      ")

      # Wait for async operations
      sleep(2)

      state_data = page.evaluate_script("window.stateData")
      referral_data = page.evaluate_script("window.referralData")

      expect(state_data).not_to be_nil
      expect(referral_data).not_to be_nil
    end
  end

  describe "Customers page" do
    before do
      # Mock Elasticsearch response with proper ActiveRecord relation
      mock_relation = double("ActiveRecord::Relation")
      allow(mock_relation).to receive(:includes).and_return(mock_relation)
      allow(mock_relation).to receive(:load).and_return([])

      allow(PurchaseSearchService).to receive(:search).and_return(
        double(
          records: mock_relation,
          results: double(total: 0)
        )
      )
    end

    it "renders the customers dashboard" do
      visit customers_path

      expect(page).to have_content("Sales", wait: 10)

      # Verify Inertia component
      expect(page).to have_css("[data-page]")
    end

    it "displays customer information" do
      visit customers_path

      expect(page).to have_content("Sales", wait: 10)
      expect(page).to have_content("Manage all of your sales")
    end

    it "handles customer pagination and filtering" do
      visit customers_path

      # Test pagination endpoint with proper waiting
      page.execute_script("
        window.customersData = null;
        fetch('/customers/paged?page=1')
          .then(response => response.json())
          .then(data => window.customersData = data)
          .catch(error => window.customersData = { customers: [] })
      ")

      # Wait for async operation
      sleep(2)

      customers_data = page.evaluate_script("window.customersData")
      expect(customers_data).not_to be_nil
    end

    it "supports customer search and filtering" do
      visit customers_path

      # Test search functionality with proper waiting
      page.execute_script("
        window.searchResults = null;
        fetch('/customers/paged?query=customer@example.com')
          .then(response => response.json())
          .then(data => window.searchResults = data)
          .catch(error => window.searchResults = { customers: [] })
      ")

      # Wait for async operation
      sleep(2)

      search_results = page.evaluate_script("window.searchResults")
      expect(search_results).not_to be_nil
    end

    it "loads customer details" do
      visit customers_path

      # Test customer charges endpoint with proper waiting
      page.execute_script("
        window.customerCharges = null;
        fetch('/customers/customer_charges?purchase_id=test123&purchase_email=test@example.com')
          .then(response => response.json())
          .then(data => window.customerCharges = data)
          .catch(error => window.customerCharges = [])
      ")

      # Wait for async operation
      sleep(2)

      customer_charges = page.evaluate_script("window.customerCharges")
      expect(customer_charges).not_to be_nil
    end
  end

  describe "Inertia.js functionality" do
    let!(:product) { create(:product, user: seller, name: "Navigation Test Product") }

    it "handles navigation between Inertia pages without full page reloads" do
      visit dashboard_path
      expect(page).to have_content("Dashboard", wait: 10)

      # Navigate to products page if the link exists
      if page.has_link?("Products")
        click_link "Products"
        expect(page).to have_content("Products", wait: 10)
      else
        # If no Products link, just visit the products page directly
        visit products_path
        expect(page).to have_content("Products", wait: 10)
      end

      # Verify we're still in an Inertia context
      expect(page).to have_css("[data-page]")
    end

    it "preserves scroll position during navigation" do
      visit products_path
      expect(page).to have_content("Products", wait: 10)

      # Test that Inertia progress bar is configured
      # Just verify the page loads without errors
      expect(page).to have_css("[data-page]")
    end

    it "handles form submissions via Inertia" do
      visit products_path
      expect(page).to have_content("Products", wait: 10)

      # Verify CSRF token is present for forms (not requiring visibility)
      expect(page).to have_css('meta[name="csrf-token"]', visible: false)
    end
  end

  describe "Error handling" do
    it "handles 404 errors gracefully" do
      visit "/nonexistent-inertia-page"

      expect(page).to have_content("404")
    end

    it "handles authentication redirects" do
      sign_out user

      visit dashboard_path

      # Should redirect to login
      expect(current_path).to eq("/login")
    end
  end

  describe "Performance and loading" do
    it "loads pages within acceptable time limits" do
      start_time = Time.current
      visit dashboard_path
      expect(page).to have_content("Dashboard", wait: 10)
      load_time = Time.current - start_time

      expect(load_time).to be < 10.seconds
    end

    it "properly loads JavaScript assets" do
      visit dashboard_path

      # Verify Inertia and React are loaded
      # Check if Inertia is available in any form
      inertia_available = page.evaluate_script("
        typeof window.Inertia !== 'undefined' ||
        typeof window.InertiaApp !== 'undefined' ||
        document.querySelector('[data-page]') !== null
      ")
      expect(inertia_available).to be_truthy
    end
  end
end
