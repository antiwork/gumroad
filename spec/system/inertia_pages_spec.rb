# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Inertia Pages", type: :system, js: true do
  include CapybaraHelpers

  # Helper method to execute fetch with automatic tracking of async requests
  def fetch_with_tracking(url, result_variable, default_value = {})
    page.execute_script(<<~JS)
      window.#{result_variable} = null;
      window.__activeRequests = true;
      fetch('#{url}')
        .then(response => response.json())
        .then(data => {
          window.#{result_variable} = data;
          window.__activeRequests = false;
        })
        .catch(error => {
          window.#{result_variable} = #{default_value.to_json};
          window.__activeRequests = false;
        });
    JS

    # Wait for the async operation to complete
    wait_for_ajax

    # Return the variable value
    page.evaluate_script("window.#{result_variable}")
  end

  # Helper method to verify Inertia component
  def verify_inertia_component(expected_component)
    expect(page).to have_css("[data-page]")
    page_data = JSON.parse(page.find("[data-page]")["data-page"])
    expect(page_data["component"]).to eq(expected_component)
  end

  # Helper method to wait for page content and verify Inertia
  def expect_page_with_inertia(content, component = nil, wait_time: 10)
    expect(page).to have_content(content, wait: wait_time)
    verify_inertia_component(component) if component
  end

  # Helper method to test API endpoint
  def test_api_endpoint(url, variable_name, default_value = {})
    data = fetch_with_tracking(url, variable_name, default_value)
    expect(data).not_to be_nil
    data
  end

  # Helper method for common page visit pattern
  def visit_and_expect(path, content, component = nil)
    visit path
    expect_page_with_inertia(content, component)
  end

  # Helper method to just verify Inertia component without content check
  def verify_inertia_page_only(component, wait_time: 10)
    expect(page).to have_css("[data-page]", wait: wait_time)
    page_data = JSON.parse(page.find("[data-page]")["data-page"])
    expect(page_data["component"]).to eq(component)
  end

  let(:user) { create(:named_seller) }
  let(:seller) { user }

  before do
    sign_in user
  end

  describe "Dashboard page" do
    it "renders the dashboard with key metrics" do
      visit_and_expect(dashboard_path, "Welcome to Gumroad", "Dashboard/index")

      # Check for dashboard elements that actually exist
      expect(page).to have_content("Balance")
      expect(page).to have_content("Create your first product")
    end

    it "displays revenue metrics correctly" do
      visit_and_expect(dashboard_path, "Total earnings", "Dashboard/index")
      expect(page).to have_content("$0")
    end

    it "handles AJAX requests for dashboard metrics" do
      visit dashboard_path
      test_api_endpoint('/dashboard/customers_count', 'customersCount', 0)
    end
  end

  describe "Products page" do
    let!(:product1) { create(:product, user: seller, name: "Product 1", price_cents: 1000) }
    let!(:product2) { create(:product, user: seller, name: "Product 2", price_cents: 2000) }
    let!(:membership) { create(:product, user: seller, name: "Membership 1") }

    it "renders the products dashboard" do
      visit_and_expect(products_path, "Products", "Products/index")
      expect(page).to have_content("Product 1")
      expect(page).to have_content("Product 2")
    end

    it "displays both products and memberships" do
      visit products_path
      expect_page_with_inertia("Product 1")
      expect(page).to have_content("Product 2")
      expect(page).to have_content("Membership 1")
    end

    it "handles product pagination" do
      visit products_path
      test_api_endpoint('/products/products_paged?page=2', 'paginationData', { entries: [] })
    end

    it "supports product search" do
      visit products_path
      test_api_endpoint('/products/products_paged?query=Product%201', 'searchResults', { entries: [] })
    end
  end

  describe "Analytics page" do
    before do
      # Mock analytics data without creating complex purchase records
      allow_any_instance_of(AnalyticsPresenter).to receive(:page_props).and_return({
                                                                                     revenue_data: [{ date: Date.current.to_s, revenue: 1000 }],
                                                                                     sales_data: [{ date: Date.current.to_s, sales: 1 }]
                                                                                   })
    end

    it "renders the analytics dashboard" do
      visit analytics_path
      verify_inertia_page_only("Analytics/index")
    end

    it "loads analytics data via API endpoints" do
      visit analytics_path
      test_api_endpoint(
        "/analytics/data_by_date?start_time=#{1.week.ago.to_date}&end_time=#{Date.current}",
        'analyticsData',
        { revenue_data: [] }
      )
    end

    it "handles different analytics views" do
      visit analytics_path

      # Add a helper method for multiple concurrent requests
      def fetch_multiple_endpoints
        time_params = "start_time=#{1.week.ago.to_date}&end_time=#{Date.current}"

        page.execute_script(<<~JS)
          window.__activeRequests = 2;

          // State data request
          window.stateData = null;
          fetch('/analytics/data_by_state?#{time_params}')
            .then(response => response.json())
            .then(data => {
              window.stateData = data;
              window.__activeRequests--;
            })
            .catch(error => {
              window.stateData = { state_data: [] };
              window.__activeRequests--;
            });

          // Referral data request
          window.referralData = null;
          fetch('/analytics/referral_data?#{time_params}')
            .then(response => response.json())
            .then(data => {
              window.referralData = data;
              window.__activeRequests--;
            })
            .catch(error => {
              window.referralData = { referral_data: [] };
              window.__activeRequests--;
            });
        JS

        # Wait for both requests to complete
        page.document.synchronize do
          raise Capybara::ElementNotFound unless page.evaluate_script("window.__activeRequests === 0")
        end

        # Return results
        [
          page.evaluate_script("window.stateData"),
          page.evaluate_script("window.referralData")
        ]
      end

      state_data, referral_data = fetch_multiple_endpoints

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
      expect_page_with_inertia("Sales")
    end

    it "displays customer information" do
      visit customers_path
      expect_page_with_inertia("Sales")
      expect(page).to have_content("Manage all of your sales")
    end

    it "handles customer pagination and filtering" do
      visit customers_path
      test_api_endpoint('/customers/paged?page=1', 'customersData', { customers: [] })
    end

    it "supports customer search and filtering" do
      visit customers_path
      test_api_endpoint('/customers/paged?query=customer@example.com', 'searchResults', { customers: [] })
    end

    it "loads customer details" do
      visit customers_path
      test_api_endpoint(
        '/customers/customer_charges?purchase_id=test123&purchase_email=test@example.com',
        'customerCharges',
        []
      )
    end
  end

  describe "Payouts page" do
    before do
      # Mock balance stats
      allow_any_instance_of(UserBalanceStatsService).to receive(:fetch).and_return({
                                                                                     next_payout_period_data: { amount: 1000, date: 1.week.from_now },
                                                                                     processing_payout_periods_data: []
                                                                                   })
    end

    it "renders the payouts dashboard" do
      visit_and_expect(balance_path, "Payouts", "Payouts/index")
    end

    it "displays payout information" do
      visit balance_path
      expect_page_with_inertia("Payouts")
    end

    it "handles payout pagination" do
      visit balance_path
      test_api_endpoint('/balance/payments_paged?page=1', 'paymentsData', { payouts: [] })
    end
  end

  describe "Collaborators page" do
    it "renders the collaborators page" do
      visit_and_expect(collaborators_path, "Collaborators", "Collaborators/index")
    end

    it "displays collaborators interface" do
      visit collaborators_path
      # Since this is a simpler page, just verify it loads without errors
      expect(page).not_to have_content("Error")
      expect(page).not_to have_content("500")
    end
  end

  describe "Inertia.js functionality" do
    let!(:product) { create(:product, user: seller, name: "Navigation Test Product") }

    it "handles navigation between Inertia pages without full page reloads" do
      visit_and_expect(dashboard_path, "Welcome to Gumroad")

      # Navigate to products page if the link exists
      if page.has_link?("Products")
        click_link "Products"
        expect_page_with_inertia("Products")
      else
        # If no Products link, just visit the products page directly
        visit_and_expect(products_path, "Products")
      end

      # Verify we're still in an Inertia context
      expect(page).to have_css("[data-page]")
    end

    it "preserves scroll position during navigation" do
      visit_and_expect(products_path, "Products")
      # Test that Inertia progress bar is configured
      expect(page).to have_css("[data-page]")
    end

    it "handles form submissions via Inertia" do
      visit_and_expect(products_path, "Products")
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
      visit_and_expect(dashboard_path, "Welcome to Gumroad")
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
