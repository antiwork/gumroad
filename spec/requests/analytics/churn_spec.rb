# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "shared_examples/creator_dashboard_page"

describe "Churn analytics", :js, :sidekiq_inline, type: :system do
  let(:seller) { create(:user, created_at: Date.new(2023, 1, 1)) }

  include_context "with switching account to user as admin for seller"

  it_behaves_like "creator dashboard page", "Analytics" do
    let(:path) { churn_dashboard_path }
  end

  it "shows the empty state" do
    visit churn_dashboard_path
    expect(page).to have_text("No subscription products yet")
    expect(page).to have_text("Churn analytics are available for creators with active subscription products")
  end

  context "with subscription products and churn data" do
    let(:monthly_product) { create(:subscription_product, user: seller, name: "Monthly Membership") }
    let(:yearly_product) { create(:subscription_product, user: seller, name: "Annual Plan") }
    let(:monthly_price) { create(:price, link: monthly_product, price_cents: 1000, recurrence: "monthly") }
    let(:yearly_price) { create(:price, link: yearly_product, price_cents: 12000, recurrence: "yearly") }

    before do
      active_sub1 = create(:subscription, link: monthly_product, user: create(:user), created_at: "2023-12-01 12:00:00")
      active_sub2 = create(:subscription, link: monthly_product, user: create(:user), created_at: "2023-12-01 12:00:00")
      new_sub = create(:subscription, link: monthly_product, user: create(:user), created_at: "2023-12-16 12:00:00")
      churned_sub1 = create(:subscription, link: monthly_product, user: create(:user),
                                           created_at: "2023-12-01 12:00:00", deactivated_at: "2023-12-20 12:00:00")
      churned_sub2 = create(:subscription, link: yearly_product, user: create(:user),
                                           created_at: "2023-12-01 12:00:00", deactivated_at: "2023-12-25 12:00:00")

      [active_sub1, active_sub2, new_sub, churned_sub1].each do |sub|
        payment_option = create(:payment_option, subscription: sub, price: monthly_price)
        sub.update!(last_payment_option: payment_option)
      end

      yearly_payment = create(:payment_option, subscription: churned_sub2, price: yearly_price)
      churned_sub2.update!(last_payment_option: yearly_payment)
    end

    it "calculates total stats" do
      visit churn_dashboard_path(from: "2023-12-01", to: "2023-12-31")

      within_section("Churn rate") { expect(page).to have_text("40.0%") }
      within_section("Last period churn rate") { expect(page).to have_text("0.0%") }
      within_section("Revenue lost") { expect(page).to have_text("$20") }
      within_section("Churned users") { expect(page).to have_text("2") }
    end

    it "allows filtering by product" do
      visit churn_dashboard_path(from: "2023-12-01", to: "2023-12-31")

      within_section("Churn rate") { expect(page).to have_text("40.0%") }
      within_section("Revenue lost") { expect(page).to have_text("$20") }
      within_section("Churned users") { expect(page).to have_text("2") }

      select_disclosure "Select products..." do
        uncheck "Annual Plan"
      end

      within_section("Churn rate") { expect(page).to have_text("25.0%") }
      within_section("Revenue lost") { expect(page).to have_text("$10") }
      within_section("Churned users") { expect(page).to have_text("1") }

      select_disclosure "Select products..." do
        check "Annual Plan"
      end

      within_section("Churn rate") { expect(page).to have_text("40.0%") }
      within_section("Revenue lost") { expect(page).to have_text("$20") }
      within_section("Churned users") { expect(page).to have_text("2") }

      select_disclosure "Select products..." do
        uncheck "Monthly Membership"
      end

      within_section("Churn rate") { expect(page).to have_text("100.0%") }
      within_section("Revenue lost") { expect(page).to have_text("$10") }
      within_section("Churned users") { expect(page).to have_text("1") }
    end

    it "allows custom date range filtering" do
      visit churn_dashboard_path(from: "2023-12-01", to: "2023-12-31")

      within_section("Churned users") { expect(page).to have_text("2") }
      within_section("Churn rate") { expect(page).to have_text("40.0%") }

      visit churn_dashboard_path(from: "2023-12-20", to: "2023-12-31")
      within_section("Churned users") { expect(page).to have_text("2") }

      visit churn_dashboard_path(from: "2023-12-01", to: "2023-12-19")
      within_section("Churned users") { expect(page).to have_text("0") }
    end

    it "prevents date ranges exceeding 31 days" do
      visit churn_dashboard_path(from: "2023-12-01", to: "2023-12-15")

      date_range_text = find('[aria-label="Date range selector"]').text
      select_disclosure date_range_text do
        click_on "Custom range..."
        fill_in "From (including)", with: "11/01/2023"
      end
      find("body").click

      using_wait_time(5) do
        expect(page).to have_alert(text: "Date range cannot exceed 31 days")
      end
      expect(page.current_url).to include("from=2023-12-01")
      expect(page.current_url).to include("to=2023-12-15")
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
  end
end
