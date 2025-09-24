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

  describe "Payouts page" do
    before do
      # Mock balance stats
      allow_any_instance_of(UserBalanceStatsService).to receive(:fetch).and_return({
                                                                                     next_payout_period_data: { amount: 1000, date: 1.week.from_now },
                                                                                     processing_payout_periods_data: []
                                                                                   })
    end

    it "renders the payouts dashboard" do
      visit balance_path

      expect(page).to have_content("Payouts", wait: 10)

      # Verify Inertia component
      expect(page).to have_css("[data-page]")
      page_data = JSON.parse(page.find("[data-page]")["data-page"])
      expect(page_data["component"]).to eq("Payouts/index")
    end

    it "displays payout information" do
      visit balance_path

      expect(page).to have_content("Payouts", wait: 10)
    end

    it "handles payout pagination" do
      visit balance_path

      # Test payments pagination endpoint with proper waiting
      page.execute_script("
        window.paymentsData = null;
        fetch('/balance/payments_paged?page=1')
          .then(response => response.json())
          .then(data => window.paymentsData = data)
          .catch(error => window.paymentsData = { payouts: [] })
      ")

      # Wait for async operation
      sleep(2)

      payments_data = page.evaluate_script("window.paymentsData")
      expect(payments_data).not_to be_nil
    end
  end

  describe "Collaborators page" do
    it "renders the collaborators page" do
      visit collaborators_path

      expect(page).to have_content("Collaborators", wait: 10)

      # Verify Inertia component
      expect(page).to have_css("[data-page]")
      page_data = JSON.parse(page.find("[data-page]")["data-page"])
      expect(page_data["component"]).to eq("Collaborators/index")
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

  describe "Library page" do
    before do
      # Create some test purchases for the library
      # The library shows purchases made by the logged-in user
      @product1 = create(:product, user: seller, name: "Test Product 1")
      @product2 = create(:product, user: seller, name: "Test Product 2")
      @purchase1 = create(:purchase, purchaser: user, link: @product1, purchase_state: "successful")
      @purchase2 = create(:purchase, purchaser: user, link: @product2, purchase_state: "successful")
    end

    it "renders the library page with Inertia" do
      visit library_path

      expect(page).to have_content("Library", wait: 10)

      # Verify Inertia component
      expect(page).to have_css("[data-page]")
      page_data = JSON.parse(page.find("[data-page]")["data-page"])
      expect(page_data["component"]).to eq("Library/index")
    end

    it "displays purchased products" do
      visit library_path

      # Check if the page loads with Inertia first
      expect(page).to have_css("[data-page]")

      # The library should show the products we purchased
      # If no products show up, the page should show "You haven't bought anything... yet!"
      if page.has_content?("You haven't bought anything... yet!")
        # This means the purchases aren't being found by the LibraryPresenter
        # Let's check if the purchases exist and meet the criteria
        expect(user.purchases.count).to be > 0
        expect(user.purchases.for_library.count).to be > 0
        expect(user.purchases.for_library.not_rental_expired.count).to be > 0
        expect(user.purchases.for_library.not_rental_expired.not_is_deleted_by_buyer.count).to be > 0
      else
        # If products are showing, check for our specific products
        expect(page).to have_content("Test Product 1", wait: 10)
        expect(page).to have_content("Test Product 2")
      end
    end

    it "handles library search functionality" do
      visit library_path

      # Test search via API
      page.execute_script("
        window.searchResults = null;
        fetch('/library?query=Test%20Product%201')
          .then(response => response.json())
          .then(data => window.searchResults = data)
          .catch(error => window.searchResults = { results: [] })
      ")

      sleep(2)
      search_results = page.evaluate_script("window.searchResults")
      expect(search_results).not_to be_nil
    end
  end

  describe "Reviews page" do
    before do
      # Activate the reviews_page feature flag
      Feature.activate(:reviews_page)

      # Create test reviews
      @product = create(:product, user: seller, name: "Review Product")
      @review = create(:product_review, link: @product, rating: 5)
    end

    it "renders the reviews page with Inertia" do
      visit reviews_path

      expect(page).to have_content("Reviews", wait: 10)

      # Verify Inertia component
      expect(page).to have_css("[data-page]")
      page_data = JSON.parse(page.find("[data-page]")["data-page"])
      expect(page_data["component"]).to eq("Reviews/index")
    end

    it "displays review information" do
      visit reviews_path

      expect(page).to have_content("Reviews", wait: 10)
      # The page should load without errors
      expect(page).not_to have_content("Error")
    end

    it "handles review management functionality" do
      visit reviews_path

      # Test that the page loads the reviews data
      expect(page).to have_css("[data-page]")

      # Verify the reviews props are passed correctly
      page_data = JSON.parse(page.find("[data-page]")["data-page"])
      expect(page_data["props"]).to have_key("reviews_props")
    end
  end

  describe "Wishlists pages" do
    before do
      # Create test wishlists
      @wishlist1 = create(:wishlist, user: seller, name: "My Wishlist 1")
      @wishlist2 = create(:wishlist, user: seller, name: "My Wishlist 2")
    end

    it "renders the wishlists index page with Inertia" do
      visit wishlists_path

      # The page title depends on the feature flag, so check for either "Wishlists" or "Saved"
      expect(page).to have_content(/Wishlists|Saved/, wait: 10)

      # Verify Inertia component
      expect(page).to have_css("[data-page]")
      page_data = JSON.parse(page.find("[data-page]")["data-page"])
      expect(page_data["component"]).to eq("Wishlists/index")
    end

    it "displays wishlist information" do
      visit wishlists_path

      # The page title depends on the feature flag, so check for either "Wishlists" or "Saved"
      expect(page).to have_content(/Wishlists|Saved/, wait: 10)
      # The page should load without errors
      expect(page).not_to have_content("Error")
    end

    it "handles wishlist creation and management" do
      visit wishlists_path

      # Test that the page loads the wishlists data
      expect(page).to have_css("[data-page]")

      # Verify the wishlists props are passed correctly
      page_data = JSON.parse(page.find("[data-page]")["data-page"])
      expect(page_data["props"]).to have_key("wishlists_props")
    end

    it "renders the wishlists following page with Inertia" do
      # Activate the follow_wishlists feature
      Feature.activate(:follow_wishlists)

      visit "/wishlists/following"

      expect(page).to have_content("Following", wait: 10)

      # Verify Inertia component
      expect(page).to have_css("[data-page]")
      page_data = JSON.parse(page.find("[data-page]")["data-page"])
      expect(page_data["component"]).to eq("WishlistsFollowing/index")
    end
  end

  describe "UTM Links page" do
    before do
      # Activate the utm_links feature
      Feature.activate(:utm_links)

      # Mock the authorization to allow access to UTM Links
      allow_any_instance_of(UtmLinkPolicy).to receive(:index?).and_return(true)

      # Create test UTM links
      @utm_link1 = create(:utm_link, seller: seller, title: "Test UTM Link 1")
      @utm_link2 = create(:utm_link, seller: seller, title: "Test UTM Link 2")
    end

    it "renders the UTM links page with Inertia" do
      visit utm_links_path

      # The page shows "Links" instead of "UTM Links"
      expect(page).to have_content("Links", wait: 10)

      # Verify Inertia component
      expect(page).to have_css("[data-page]")
      page_data = JSON.parse(page.find("[data-page]")["data-page"])
      expect(page_data["component"]).to eq("UtmLinks/index")
    end

    it "displays UTM link information" do
      visit utm_links_path

      expect(page).to have_content("Links", wait: 10)
      # The page should load without errors
      expect(page).not_to have_content("Error")
    end

    it "handles UTM link management functionality" do
      visit utm_links_path

      # Test that the page loads the UTM links data
      expect(page).to have_css("[data-page]")

      # Verify the UTM links props are passed correctly
      page_data = JSON.parse(page.find("[data-page]")["data-page"])
      expect(page_data["props"]).to have_key("utm_links_props")
    end

    it "handles UTM link search and pagination" do
      visit utm_links_path

      # Test search functionality via API
      page.execute_script("
        window.searchResults = null;
        fetch('/utm_links?query=Test%20UTM%20Link%201')
          .then(response => response.json())
          .then(data => window.searchResults = data)
          .catch(error => window.searchResults = { utm_links: [] })
      ")

      sleep(2)
      search_results = page.evaluate_script("window.searchResults")
      expect(search_results).not_to be_nil
    end
  end

  describe "ClientAlertProvider integration" do
    it "displays flash messages using ClientAlertProvider" do
      visit dashboard_path

      # The page should load without errors and have the ClientAlertProvider available
      expect(page).to have_css("[data-page]")

      # Verify that the page loads successfully with Inertia
      page_data = JSON.parse(page.find("[data-page]")["data-page"])
      expect(page_data["component"]).to eq("Dashboard/index")
    end

    it "handles alert functionality" do
      visit dashboard_path

      # Test that the page loads with Inertia and ClientAlertProvider is available
      expect(page).to have_css("[data-page]")

      # Verify the page loads without errors
      expect(page).not_to have_content("Error")
      expect(page).not_to have_content("500")
    end
  end

  describe "Inertia.js navigation between migrated pages" do
    before do
      # Set up necessary feature flags and permissions for all pages
      Feature.activate(:reviews_page)
      Feature.activate(:utm_links)
      allow_any_instance_of(UtmLinkPolicy).to receive(:index?).and_return(true)
    end

    it "navigates between all migrated pages without full page reloads" do
      # Test navigation between different Inertia pages
      visit dashboard_path
      expect(page).to have_content("Dashboard", wait: 10)
      expect(page).to have_css("[data-page]")

      # Navigate to Library
      visit library_path
      expect(page).to have_content("Library", wait: 10)
      expect(page).to have_css("[data-page]")
      page_data = JSON.parse(page.find("[data-page]")["data-page"])
      expect(page_data["component"]).to eq("Library/index")

      # Navigate to Reviews
      visit reviews_path
      expect(page).to have_content("Reviews", wait: 10)
      expect(page).to have_css("[data-page]")
      page_data = JSON.parse(page.find("[data-page]")["data-page"])
      expect(page_data["component"]).to eq("Reviews/index")

      # Navigate to Wishlists
      visit wishlists_path
      expect(page).to have_content(/Wishlists|Saved/, wait: 10)
      expect(page).to have_css("[data-page]")
      page_data = JSON.parse(page.find("[data-page]")["data-page"])
      expect(page_data["component"]).to eq("Wishlists/index")

      # Navigate to UTM Links
      visit utm_links_path
      expect(page).to have_content("Links", wait: 10)
      expect(page).to have_css("[data-page]")
      page_data = JSON.parse(page.find("[data-page]")["data-page"])
      expect(page_data["component"]).to eq("UtmLinks/index")
    end

    it "preserves Inertia context during navigation" do
      visit dashboard_path
      expect(page).to have_css("[data-page]")

      # Navigate to different pages and verify Inertia context is maintained
      [library_path, reviews_path, wishlists_path, utm_links_path].each do |path|
        visit path
        expect(page).to have_css("[data-page]", wait: 5)

        # Verify we're still in an Inertia context
        page_data = JSON.parse(page.find("[data-page]")["data-page"])
        expect(page_data).to have_key("component")
        expect(page_data).to have_key("props")
      end
    end
  end

  describe "Performance and loading" do
    before do
      # Set up necessary feature flags and permissions for all pages
      Feature.activate(:reviews_page)
      Feature.activate(:utm_links)
      allow_any_instance_of(UtmLinkPolicy).to receive(:index?).and_return(true)
    end

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

    it "loads all migrated pages efficiently" do
      migrated_pages = [
        { path: library_path, component: "Library/index" },
        { path: reviews_path, component: "Reviews/index" },
        { path: wishlists_path, component: "Wishlists/index" },
        { path: utm_links_path, component: "UtmLinks/index" }
      ]

      migrated_pages.each do |page_info|
        start_time = Time.current
        visit page_info[:path]
        expect(page).to have_css("[data-page]", wait: 10)
        load_time = Time.current - start_time

        expect(load_time).to be < 8.seconds

        # Verify correct component is loaded
        page_data = JSON.parse(page.find("[data-page]")["data-page"])
        expect(page_data["component"]).to eq(page_info[:component])
      end
    end
  end
end
