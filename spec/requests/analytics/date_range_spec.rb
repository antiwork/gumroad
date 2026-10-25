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

    it "selects presets and opens custom dates using the keyboard" do
      visit sales_dashboard_path

      trigger = find('[aria-label="Date range selector"]').ancestor("button")
      trigger.send_keys(:enter)
      expect(page.evaluate_script("document.activeElement.textContent")).to eq("Today")
      page.driver.browser.switch_to.active_element.send_keys(:arrow_down, :enter)
      expect(page).to have_current_path(sales_dashboard_path(from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601))

      find('[aria-label="Date range selector"]').ancestor("button").send_keys(:enter)
      page.driver.browser.switch_to.active_element.send_keys(:arrow_up, :space)
      expect(page).to have_field("From (including)")
      expect(page.evaluate_script("document.activeElement.id")).to eq(find_field("From (including)")[:id])
      page.driver.browser.switch_to.active_element.send_keys(:escape)
      expect(page).not_to have_field("From (including)")
      expect(page.evaluate_script("document.activeElement.getAttribute('aria-expanded')")).to eq("false")
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
