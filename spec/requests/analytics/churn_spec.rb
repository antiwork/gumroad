# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "shared_examples/creator_dashboard_page"

describe "Churn analytics", :js, :sidekiq_inline, :elasticsearch_wait_for_refresh, type: :system do
  let(:seller) { create(:user, timezone: "UTC", created_at: Date.new(2023, 1, 1)) }

  before do
    Feature.activate_user(:churn_analytics_enabled, seller)
  end

  include_context "with switching account to user as admin for seller"

  def create_subscription_purchase(
    product:,
    created_at:,
    subscription_cancelled_at: nil,
    subscription_deactivated_at: nil,
    price_cents: 100
  )
    price = create(:price, link: product, price_cents:, recurrence: BasePrice::Recurrence::MONTHLY)
    subscription = create(
      :subscription,
      link: product,
      user: seller,
      cancelled_at: subscription_cancelled_at,
      deactivated_at: subscription_deactivated_at,
      price:
    )
    create(
      :purchase,
      link: product,
      seller:,
      subscription:,
      is_original_subscription_purchase: true,
      created_at:,
      price_cents:
    )
  end

  it_behaves_like "creator dashboard page", "Analytics" do
    let(:path) { churn_dashboard_path }
  end

  context "without subscription products" do
    it "shows the empty state" do
      visit churn_dashboard_path

      expect(page).to have_text("No subscription products yet")
      expect(page).to have_link("Learn more about memberships")
      expect(page).not_to have_css('[data-testid="chart-dot"]')
      expect(page).not_to have_select("Aggregate by")
    end
  end

  context "with subscription products and churn data" do
    let(:product_a) { create(:product, :is_subscription, user: seller, name: "Product A") }
    let(:product_b) { create(:product, :is_subscription, user: seller, name: "Product B") }

    before do
      # Product A: 10 active subscribers, 2 churned at $25 each = $50 lost
      10.times { create_subscription_purchase(product: product_a, created_at: "2023-12-01", price_cents: 2500) }
      2.times do
        create_subscription_purchase(
          product: product_a,
          created_at: "2023-12-01",
          subscription_cancelled_at: "2023-12-15",
          subscription_deactivated_at: "2023-12-15",
          price_cents: 2500
        )
      end

      # Product B: 5 active subscribers, 1 churned at $30 = $30 lost
      5.times { create_subscription_purchase(product: product_b, created_at: "2023-12-01", price_cents: 3000) }
      create_subscription_purchase(
        product: product_b,
        created_at: "2023-12-01",
        subscription_cancelled_at: "2023-12-15",
        subscription_deactivated_at: "2023-12-15",
        price_cents: 3000
      )

      index_model_records(Purchase)
    end

    describe "quick stats" do
      it "displays all stat boxes when no previous period" do
        visit churn_dashboard_path(from: "2023-12-01", to: "2023-12-31")

        # 18 total subscriptions (10 Product A active + 2 Product A churned + 5 Product B active + 1 Product B churned)
        # All created on 2023-12-01 (start of period), so all count as new subscriptions
        # 3 churned = (3 / 18) * 100 = 16.67%
        within_section("Churn rate") { expect(page).to have_text("16.67%") }
        within_section("Last period churn rate") { expect(page).to have_text("—") }
        within_section("Churned users") { expect(page).to have_text("3") }
        within_section("Revenue lost") { expect(page).to have_text("$80") }
      end

      context "with previous period data" do
        before do
          # Previous period: 2023-12-09 to 2023-12-14 (6 days, ending one day before current period)
          # Current period: 2023-12-15 to 2023-12-20 (6 days)
          # Setup: 19 total subscriptions (10 Product A active + 2 Product A churned in current + 5 Product B active + 1 Product B churned in current + 1 Product A churned in previous)
          # All 19 were active at start of previous period (all created 2023-12-01)
          # 1 churned in previous period (2023-12-10)
          # Previous period churn rate = (1 / 19) * 100 = 5.26%
          create_subscription_purchase(
            product: product_a,
            created_at: "2023-12-01",
            subscription_cancelled_at: "2023-12-10",
            subscription_deactivated_at: "2023-12-10",
            price_cents: 2500
          )
          index_model_records(Purchase)
        end

        it "displays previous period churn rate when previous period exists" do
          visit churn_dashboard_path(from: "2023-12-15", to: "2023-12-20")

          within_section("Last period churn rate") { expect(page).to have_text("5.26%") }
        end
      end

      it "recalculates stats when products are filtered" do
        visit churn_dashboard_path(from: "2023-12-01", to: "2023-12-31")

        within_section("Churned users") { expect(page).to have_text("3") }
        within_section("Revenue lost") { expect(page).to have_text("$80") }

        select_disclosure "Select products..." do
          uncheck "Product B"
        end

        within_section("Churned users") { expect(page).to have_text("2") }
        within_section("Revenue lost") { expect(page).to have_text("$50") }
      end
    end

    describe "chart" do
      it "renders data points for each day in range" do
        visit churn_dashboard_path(from: "2023-12-01", to: "2023-12-07")

        expect(page).to have_css('[data-testid="chart-dot"]', count: 7)
      end

      it "shows tooltip with churn details on hover" do
        visit churn_dashboard_path(from: "2023-12-14", to: "2023-12-16")

        chart = find('[data-testid="chart"]')
        chart.hover

        expect(chart).to have_tooltip(text: /churn/)
        expect(chart).to have_tooltip(text: /cancellation/)
        expect(chart).to have_tooltip(text: /revenue lost/)
      end

      it "reduces to monthly buckets when aggregate changed" do
        visit churn_dashboard_path(from: "2023-12-01", to: "2023-12-31")

        expect(page).to have_css('[data-testid="chart-dot"]', count: 31)

        select "Monthly", from: "Aggregate by"

        expect(page).to have_css('[data-testid="chart-dot"]', count: 1)
      end

      it "shows zero values when date range has no churn events" do
        visit churn_dashboard_path(from: "2023-12-01", to: "2023-12-07")

        within_section("Churned users") { expect(page).to have_text("0") }
        expect(page).to have_css('[data-testid="chart-dot"]')
      end
    end

    describe "date range picker" do
      it "updates URL when date range changes" do
        visit churn_dashboard_path(from: "2023-12-01", to: "2023-12-31")

        find('[aria-label="Date range selector"]').click
        click_on "Custom range..."
        fill_in "From (including)", with: "12/15/2023"
        fill_in "To (including)", with: "12/20/2023"
        find("body").click

        wait_for_ajax
        expect(page).to have_current_path(churn_dashboard_path(from: "2023-12-15", to: "2023-12-20"))
        expect(page).to have_css('[data-testid="chart-dot"]', count: 6)
      end

      it "auto-corrects when from date is after to date" do
        visit churn_dashboard_path(from: "2023-12-20", to: "2023-12-01")

        expect(page).to have_current_path(churn_dashboard_path(from: "2023-12-20", to: "2023-12-20"))
      end
    end

    describe "product filter" do
      it "updates stats and chart when products are deselected" do
        visit churn_dashboard_path(from: "2023-12-01", to: "2023-12-31")

        within_section("Churned users") { expect(page).to have_text("3") }

        select_disclosure "Select products..." do
          uncheck "Product B"
        end

        within_section("Churned users") { expect(page).to have_text("2") }
        expect(page).to have_css('[data-testid="chart-dot"]')
      end
    end
  end
end
