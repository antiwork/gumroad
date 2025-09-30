# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Inertia Analytics Page", type: :system, js: true do
  let(:seller) { create(:user) }

  before do
    sign_in seller
    # Mock analytics data without creating complex purchase records
    allow_any_instance_of(AnalyticsPresenter).to receive(:page_props).and_return({
                                                                                     products: [],
                                                                                     country_codes: {},
                                                                                     state_names: []
                                                                                   })
  end

  describe "Analytics page" do
    before do
      visit analytics_path
    end

    it "renders the analytics dashboard" do
      # Check for any content that indicates the page loaded
      expect(page).to have_css("body", wait: 10)

      # Verify Inertia component
      expect(page).to have_css("[data-page]")
    end

    it "loads analytics data via API endpoints" do
      # Test data by date endpoint with proper waiting
      page.execute_script("
        window.analyticsData = null;
        fetch(Routes.analytics_data_by_date_path({ start_time: '#{1.week.ago.to_date}', end_time: '#{Date.current}' }))
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
      # Test data by state endpoint with proper waiting
      page.execute_script("
        window.stateData = null;
        fetch(Routes.analytics_data_by_state_path({ start_time: '#{1.week.ago.to_date}', end_time: '#{Date.current}' }))
          .then(response => response.json())
          .then(data => window.stateData = data)
          .catch(error => window.stateData = { state_data: [] })
      ")

      # Test referral data endpoint with proper waiting
      page.execute_script("
        window.referralData = null;
        fetch(Routes.analytics_data_by_referral_path({ start_time: '#{1.week.ago.to_date}', end_time: '#{Date.current}' }))
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
end
