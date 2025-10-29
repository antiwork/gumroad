# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "shared_examples/creator_dashboard_page"

describe "Churn analytics", :js, :sidekiq_inline, type: :system do
  include ChurnTestHelpers

  let(:seller) { create(:user, created_at: Date.new(2023, 1, 1)) }

  include_context "with switching account to user as admin for seller"

  context "without subscription products" do
    it "denies access to the churn page" do
      visit churn_dashboard_path
      # User is redirected to dashboard when not authorized
      expect(page).to have_current_path(dashboard_path)
    end
  end

  context "with subscription products" do
    let!(:subscription_product) { create(:subscription_product, user: seller, name: "Test Membership") }

    it_behaves_like "creator dashboard page", "Analytics" do
      let(:path) { churn_dashboard_path }
    end

    it "shows the churn page with zero data when there are no subscribers" do
      visit churn_dashboard_path
      expect(page).to have_text("Churn rate")
      expect(page).to have_text("0.0%")
      expect(page).to have_text("Churned users")
      expect(page).to have_text("0")
    end
  end

  context "with subscription products and churn data" do
    let(:monthly_product) { create(:subscription_product, user: seller, name: "Monthly Membership") }
    let(:yearly_product) { create(:subscription_product, user: seller, name: "Annual Plan") }
    let(:monthly_price) { create(:price, link: monthly_product, price_cents: 1000, recurrence: "monthly") }
    let(:yearly_price) { create(:price, link: yearly_product, price_cents: 12000, recurrence: "yearly") }

    before do
      setup_churn_scenario(
        monthly_product: monthly_product,
        yearly_product: yearly_product,
        monthly_price: monthly_price,
        yearly_price: yearly_price
      )
    end

    it "calculates total stats correctly" do
      visit churn_dashboard_path(from: "2023-12-01", to: "2023-12-31")

      # Expected calculation:
      # - Active at start: 2 subscriptions
      # - New during period: 1 subscription
      # - Churned: 2 subscriptions
      # - Total base: 2 + 1 + 2 = 5 (Stripe formula includes churned in base)
      # - Churn rate: 2/5 = 40%
      # - Revenue lost: $10 (monthly) + $10 (yearly MRR = $12000/12) = $20
      expect_churn_metrics(
        churn_rate: "40.0",
        last_period_rate: "0.0",
        revenue_lost: "20",
        churned_users: 2
      )
    end

    it "allows filtering by product" do
      visit churn_dashboard_path(from: "2023-12-01", to: "2023-12-31")

      # Initial state: both products selected
      expect_churn_metrics(churn_rate: "40.0", last_period_rate: "0.0", revenue_lost: "20", churned_users: 2)

      # Deselect Annual Plan - only monthly product
      select_disclosure "Select products..." do
        uncheck "Annual Plan"
      end

      # Expected: 1 churned / 4 total = 25%
      expect_churn_metrics(churn_rate: "25.0", last_period_rate: "0.0", revenue_lost: "10", churned_users: 1)

      # Re-select Annual Plan
      select_disclosure "Select products..." do
        check "Annual Plan"
      end

      expect_churn_metrics(churn_rate: "40.0", last_period_rate: "0.0", revenue_lost: "20", churned_users: 2)

      # Deselect Monthly Membership - only yearly product
      select_disclosure "Select products..." do
        uncheck "Monthly Membership"
      end

      # Expected: 1 churned / 1 total = 100%
      expect_churn_metrics(churn_rate: "100.0", last_period_rate: "0.0", revenue_lost: "10", churned_users: 1)
    end

    it "allows custom date range filtering" do
      visit churn_dashboard_path(from: "2023-12-01", to: "2023-12-31")

      within_section("Churned users") { expect(page).to have_text("2") }
      within_section("Churn rate") { expect(page).to have_text("40.0%") }

      # Filter to period including both churn events (Dec 20 and Dec 25)
      visit churn_dashboard_path(from: "2023-12-20", to: "2023-12-31")
      within_section("Churned users") { expect(page).to have_text("2") }

      # Filter to period before any churn events
      visit churn_dashboard_path(from: "2023-12-01", to: "2023-12-19")
      within_section("Churned users") { expect(page).to have_text("0") }
    end

    it "supports quick date range selections" do
      visit churn_dashboard_path(from: "2023-12-01", to: "2023-12-31")

      date_range_text = find('[aria-label="Date range selector"]').text
      select_disclosure date_range_text do
        expect(page).to have_text("Last 30 days")
        expect(page).to have_text("This month")
        expect(page).to have_text("Last month")
        expect(page).to have_text("Custom range...")
      end
    end

    it "handles date range with no churn data" do
      # Period before any subscriptions
      visit churn_dashboard_path(from: "2023-01-01", to: "2023-01-31")

      expect_churn_metrics(
        churn_rate: "0.0",
        last_period_rate: "0.0",
        revenue_lost: "0",
        churned_users: 0
      )

      # Chart should still render
      expect(page).to have_css(".recharts-wrapper")
    end

    it "toggles between daily and monthly aggregation" do
      visit churn_dashboard_path(from: "2023-12-01", to: "2023-12-31")

      # Default is daily
      expect(page).to have_select("Aggregate by", selected: "Daily")

      # Switch to monthly
      select "Monthly", from: "Aggregate by"

      # Verify URL updated
      expect(page.current_url).to include("from=2023-12-01")
      expect(page.current_url).to include("to=2023-12-31")

      # Chart should still render
      expect(page).to have_css(".recharts-wrapper")

      # Metrics should remain the same regardless of aggregation
      expect_churn_metrics(
        churn_rate: "40.0",
        last_period_rate: "0.0",
        revenue_lost: "20",
        churned_users: 2
      )

      # Switch back to daily
      select "Daily", from: "Aggregate by"
      expect(page).to have_css(".recharts-wrapper")
    end

    it "validates URL parameters are updated on filter changes" do
      visit churn_dashboard_path(from: "2023-12-01", to: "2023-12-31")

      # Verify date parameters are in URL
      expect(page.current_url).to include("from=2023-12-01")
      expect(page.current_url).to include("to=2023-12-31")

      # Change product filter
      select_disclosure "Select products..." do
        uncheck "Annual Plan"
      end

      # URL should update with product parameter after filtering
      expect(page.current_url).to match(/products\[\]=\d+/)

      # Select all products again
      select_disclosure "Select products..." do
        check "Annual Plan"
      end

      # URL should reflect the change
      expect(page.current_url).to include("from=2023-12-01")
      expect(page.current_url).to include("to=2023-12-31")
    end
  end

  context "with boundary date scenarios" do
    let(:monthly_product) { create(:subscription_product, user: seller, name: "Monthly Membership") }
    let(:monthly_price) { create(:price, link: monthly_product, price_cents: 1000, recurrence: "monthly") }

    it "handles subscriptions created at exact period start" do
      create_new_subscription(
        product: monthly_product,
        price: monthly_price,
        created_at: "2023-12-01 00:00:00"
      )

      visit churn_dashboard_path(from: "2023-12-01", to: "2023-12-31")

      # New subscription should be counted
      within_section("Churned users") { expect(page).to have_text("0") }
      expect(page).to have_css(".recharts-wrapper")
    end

    it "handles subscriptions churned at exact period end" do
      create_churned_subscription(
        product: monthly_product,
        price: monthly_price,
        created_at: "2023-11-01 12:00:00",
        deactivated_at: "2023-12-31 23:59:59"
      )

      visit churn_dashboard_path(from: "2023-12-01", to: "2023-12-31")

      # Churned subscription should be counted
      within_section("Churned users") { expect(page).to have_text("1") }
    end

    it "handles multiple churns on the same day" do
      3.times do
        create_churned_subscription(
          product: monthly_product,
          price: monthly_price,
          created_at: "2023-11-01 12:00:00",
          deactivated_at: "2023-12-15 14:30:00"
        )
      end

      visit churn_dashboard_path(from: "2023-12-01", to: "2023-12-31")

      within_section("Churned users") { expect(page).to have_text("3") }
      within_section("Revenue lost") { expect(page).to have_text("$30") }
    end
  end

  context "with large date ranges" do
    let(:monthly_product) { create(:subscription_product, user: seller, name: "Monthly Membership") }
    let(:monthly_price) { create(:price, link: monthly_product, price_cents: 1000, recurrence: "monthly") }

    it "handles date ranges spanning multiple months" do
      create_churned_subscription(
        product: monthly_product,
        price: monthly_price,
        created_at: "2023-01-01 12:00:00",
        deactivated_at: "2023-06-15 12:00:00"
      )

      visit churn_dashboard_path(from: "2023-01-01", to: "2023-12-31")

      within_section("Churned users") { expect(page).to have_text("1") }
      expect(page).to have_css(".recharts-wrapper")
    end
  end
end
