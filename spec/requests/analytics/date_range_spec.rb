# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "shared_examples/creator_dashboard_page"

describe "Analytics date range", :js, :sidekiq_inline, type: :system do
  let(:seller) { create(:user, created_at: Date.new(2023, 1, 1)) }
  let(:test_date) { Date.today }

  include_context "with switching account to user as admin for seller"

  context "with an existing product" do
    let(:product) { create(:product, user: seller, name: "Product 1") }

    before do
      create(:purchase, link: product, price_cents: 100, created_at: test_date.beginning_of_month, ip_country: "Italy")
      recreate_model_index(ProductPageView)
    end

    it "allows selecting 'This month' date range" do
      travel_to test_date do
        visit sales_dashboard_path

        # Find and click the date range selector
        find('[aria-label="Date range selector"]').click
        click_on "This month"

        # The URL should be updated with the date range
        expect(page).to have_current_path(sales_dashboard_path(from: test_date.beginning_of_month.strftime("%Y-%m-%d"), to: test_date.strftime("%Y-%m-%d")))
      end
    end
  end
end
