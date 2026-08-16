# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "shared_examples/creator_dashboard_page"

describe "Sales analytics", :js, :sidekiq_inline, :elasticsearch_wait_for_refresh, type: :system do
  let(:seller) { create(:user, created_at: Date.new(2023, 1, 1)) }

  include_context "with switching account to user as admin for seller"

  it_behaves_like "creator dashboard page", "Analytics" do
    let(:path) { sales_dashboard_path }
  end

  it "shows the empty state" do
    visit sales_dashboard_path
    expect(page).to have_text("You don't have any sales yet.")
  end

  context "with the date range picker" do
    let!(:product) { create(:product, user: seller) }

    it "does not clamp the URL when the requested range exceeds 366 days" do
      visit sales_dashboard_path(from: "2020-01-01", to: "2024-06-01")
      expect(page).to have_current_path(sales_dashboard_path(from: "2020-01-01", to: "2024-06-01"))
    end

    # The stubbed 500s below are the scenario under test, not incidental breakage. Capybara stores
    # the raised error and re-raises it at teardown, so each example clears it before restoring the
    # setting.
    def failing_analytics_loads(succeeds_within_days: nil)
      Capybara.raise_server_errors = false
      allow_any_instance_of(CreatorAnalytics::CachingProxy).to receive(:data_for_dates).and_wrap_original do |original, start_date, end_date, **kwargs|
        raise "boom" if succeeds_within_days.nil? || (end_date - start_date).to_i > succeeds_within_days
        original.call(start_date, end_date, **kwargs)
      end
      yield
    ensure
      Capybara.current_session.server&.reset_error!
      Capybara.raise_server_errors = true
    end

    it "halves the range until a load succeeds and emails the full range as a CSV" do
      failing_analytics_loads(succeeds_within_days: 400) do
        expect do
          visit sales_dashboard_path(from: "2020-01-01", to: "2024-01-01")
          # The alert names the range that was exported, not "the full range" — by then the picker
          # has moved to a narrower one.
          expect(page).to have_text(%r{A CSV of .*2020.*2024.* is on its way to your email\.}, wait: 20)
          # 1461 days fails, 730 fails, 365 loads.
          expect(page).to have_current_path(/from=2023-01-01.*to=2024-01-01/, wait: 20)
          expect(page).to have_no_text("Loading sales chart…", wait: 20)
          # sidekiq_inline runs the export pipeline to completion, so assert on the delivered email.
        end.to change { ActionMailer::Base.deliveries.size }.by(1)
      end

      expect(ActionMailer::Base.deliveries.last.to).to eq([user_with_role_for_seller.email])
    end

    # rangeDays counts the gap between two included dates, so the halving has to keep going at
    # rangeDays == 1 (two days) and actually try the single day before giving up.
    it "halves down to a single day when every load fails" do
      failing_analytics_loads do
        expect do
          visit sales_dashboard_path(from: "2020-01-01", to: "2024-01-01")
          expect(page).to have_text("Sorry, something went wrong. Please try again.", wait: 30)
          expect(page).to have_current_path(/from=2024-01-01.*to=2024-01-01/, wait: 20)
        end.to change { ActionMailer::Base.deliveries.size }.by(1)
      end
    end

    it "does not promise an emailed CSV when the export cannot be enqueued" do
      allow(Exports::PurchaseExportService).to receive(:export).and_raise("no export for you")

      failing_analytics_loads(succeeds_within_days: 400) do
        expect do
          visit sales_dashboard_path(from: "2020-01-01", to: "2024-01-01")
          expect(page).to have_text("This range couldn't load, so we're retrying with the most recent half.", wait: 20)
          expect(page).to have_current_path(/from=2023-01-01.*to=2024-01-01/, wait: 20)
        end.not_to change { ActionMailer::Base.deliveries.size }
      end

      expect(page).to have_no_text("on its way to your email")
    end

    it "defaults to monthly aggregation for ranges wider than 366 days" do
      visit sales_dashboard_path(from: "2020-01-01", to: "2024-06-01")
      expect(page).to have_select("Aggregate by", selected: "Monthly")
    end

    it "keeps daily aggregation for ranges within 366 days" do
      visit sales_dashboard_path(from: "2024-01-01", to: "2024-06-01")
      expect(page).to have_select("Aggregate by", selected: "Daily")
    end

    it "offers the All time preset" do
      visit sales_dashboard_path
      initial = find('[aria-label="Date range selector"]').text
      select_disclosure initial do
        expect(page).to have_content("All time")
        expect(page).to have_content("Last 30 days")
        expect(page).to have_content("Last year")
      end
    end

    # The backend clamps every range to the seller's creation date, so a preset that starts
    # earlier would draw a chart the picker disagrees with.
    it "starts All time at the seller's creation date" do
      # Noon UTC is the same calendar day in the seller's Pacific time zone, so the expected
      # date below doesn't depend on the offset.
      seller.update!(created_at: Time.utc(2021, 5, 20, 12, 0, 0))

      visit sales_dashboard_path
      initial = find('[aria-label="Date range selector"]').text
      select_disclosure initial do
        click_on "All time"
      end
      expect(page).to have_current_path(/from=2021-05-20/)
    end

    it "accepts a custom range wider than 366 days" do
      visit sales_dashboard_path
      initial = find('[aria-label="Date range selector"]').text
      select_disclosure initial do
        click_on "Custom range..."
        fill_in "From (including)", with: "01/01/2020"
        fill_in "To (including)", with: "01/01/2024"
      end
      # DateInput only commits on blur. Filling From then To blurs From (so `from`
      # lands in the URL) but leaves To focused — without this click, `to` stays
      # at today. Same pattern as the "calculates total stats" custom-range step.
      find("body").click
      expect(page).not_to have_text("Range can be at most")
      expect(page).to have_current_path(sales_dashboard_path(from: "2020-01-01", to: "2024-01-01"))
    end

    it "shows the export confirmation popover linking to the unfiltered export" do
      visit sales_dashboard_path
      select_disclosure "Export all sales" do
        expect(page).to have_text("You'll get a CSV of every sale you've made. Large exports arrive by email.")
        expect(page).to have_link("Export", href: export_purchases_path)
      end
    end
  end

  context "with views and sales" do
    let(:product1) { create(:product, user: seller, name: "Product 1") }
    let(:product2) { create(:product, user: seller, name: "Product 2") }

    before do
      create(:purchase, link: product1, price_cents: 100, created_at: "2023-12-14 12:00:00", ip_country: "Italy")
      create(:purchase, link: product1, price_cents: 100, created_at: "2023-12-14 12:00:00", ip_country: "Italy", referrer: "https://google.com")
      create(:purchase, link: product2, price_cents: 500, created_at: "2023-12-16 12:00:00", ip_country: "United States", ip_state: "NY")
      create(:purchase, link: product2, price_cents: 500, created_at: "2023-12-20 12:00:00", ip_country: "Japan")
      recreate_model_index(ProductPageView)
      3.times { add_page_view(product1, Time.zone.parse("2023-12-13 12:00:00").iso8601, country: "Italy", referrer_domain: "google.com") }
      3.times { add_page_view(product2, Time.zone.parse("2023-12-16 12:00:00").iso8601, country: "United States", state: "CA") }
    end

    it "calculates total stats" do
      visit sales_dashboard_path(from: "2023-12-01", to: "2023-12-31")
      within_section("Sales") { expect(page).to have_text("4") }
      within_section("Views") { expect(page).to have_text("6") }
      within_section("Total") { expect(page).to have_text("$12") }

      select_disclosure "Select products..." do
        uncheck "Product 1"
      end
      within_section("Sales") { expect(page).to have_text("2") }
      within_section("Views") { expect(page).to have_text("3") }
      within_section("Total") { expect(page).to have_text("$10") }

      select_disclosure "12/1/2023 – 12/31/2023" do
        click_on "Custom range..."
        fill_in "From (including)", with: "12/16/2023"
        fill_in "To (including)", with: "12/17/2023"
      end
      find("body").click # Blur the date field to trigger the update

      expect(page).to have_current_path(sales_dashboard_path(from: "2023-12-16", to: "2023-12-17"))
      within_section("Sales") { expect(page).to have_text("1") }
      within_section("Views") { expect(page).to have_text("3") }
      within_section("Total") { expect(page).to have_text("$5") }
    end

    it "shows the sales chart" do
      visit sales_dashboard_path(from: "2023-12-01", to: "2023-12-31")
      expect(page).to have_css('[data-testid="chart-dot"]', count: 31)
      expect(page).to have_css('[data-testid="chart-bar"]', count: 5)

      chart = find('[data-testid="chart"]')
      chart.hover
      expect(chart).to have_tooltip(text: "3 views\n1 sale\n(33.3% conversion)\n$5\nSaturday, December 16")

      select "Monthly", from: "Aggregate by"
      expect(page).to have_css('[data-testid="chart-dot"]', count: 1)
      expect(page).to have_css('[data-testid="chart-bar"]', count: 2)
      chart.hover
      expect(chart).to have_tooltip(text: "6 views\n4 sales\n(66.7% conversion)\n$12\nDecember 2023")

      select "Daily", from: "Aggregate by"

      select_disclosure "Select products..." do
        uncheck "Product 1"
      end
      expect(page).to have_css('[data-testid="chart-bar"]', count: 3)

      select_disclosure "12/1/2023 – 12/31/2023" do
        click_on "Custom range..."
        fill_in "From (including)", with: "12/16/2023"
        fill_in "To (including)", with: "12/17/2023"
      end
      find("body").click # Blur the date field to trigger the update

      expect(page).to have_css('[data-testid="chart-dot"]', count: 2)
      expect(page).to have_css('[data-testid="chart-bar"]', count: 2)
    end

    it "shows the referrers table" do
      visit sales_dashboard_path(from: "2023-12-01", to: "2023-12-31")
      within_table("Referrer") do
        expect(page).to have_table_row({ "Source" => "Direct, email, IM", "Views" => "3", "Sales" => "3", "Conversion" => "100%", "Total" => "$11" })
        expect(page).to have_table_row({ "Source" => "Google", "Views" => "3", "Sales" => "1", "Conversion" => "33.3%", "Total" => "$1" })
      end

      select_disclosure "Select products..." do
        uncheck "Product 1"
      end
      within_table("Referrer") do
        expect(page).not_to have_table_row({ "Source" => "Google" })
        expect(page).to have_table_row({ "Source" => "Direct, email, IM", "Views" => "3", "Sales" => "2", "Conversion" => "66.7%", "Total" => "$10" })
      end

      select_disclosure "12/1/2023 – 12/31/2023" do
        click_on "Custom range..."
        fill_in "From (including)", with: "12/16/2023"
        fill_in "To (including)", with: "12/17/2023"
      end
      find("body").click # Blur the date field to trigger the update
      within_table("Referrer") do
        expect(page).not_to have_table_row({ "Source" => "Google" })
        expect(page).to have_table_row({ "Source" => "Direct, email, IM", "Views" => "3", "Sales" => "1", "Conversion" => "33.3%", "Total" => "$5" })
      end
    end

    it "shows the locations table" do
      visit sales_dashboard_path(from: "2023-12-01", to: "2023-12-31")
      within_table("Locations") do
        expect(page).to have_table_rows_in_order(
          [
            { "Country" => "🇺🇸 United States", "Views" => "3", "Sales" => "1", "Total" => "$5" },
            { "Country" => "🇯🇵 Japan", "Views" => "0", "Sales" => "1", "Total" => "$5" },
            { "Country" => "🇮🇹 Italy", "Views" => "3", "Sales" => "2", "Total" => "$2" },
          ]
        )
      end

      select_disclosure "Select products..." do
        uncheck "Product 1"
      end
      within_table("Locations") do
        expect(page).not_to have_table_row({ "Country" => "🇮🇹 Italy" })
        expect(page).to have_table_row({ "Country" => "🇺🇸 United States", "Views" => "3", "Sales" => "1", "Total" => "$5" })
        expect(page).to have_table_row({ "Country" => "🇯🇵 Japan", "Views" => "0", "Sales" => "1", "Total" => "$5" })
      end

      select_disclosure "12/1/2023 – 12/31/2023" do
        click_on "Custom range..."
        fill_in "From (including)", with: "12/16/2023"
        fill_in "To (including)", with: "12/17/2023"
      end
      find("body").click # Blur the date field to trigger the update
      within_table("Locations") do
        expect(page).not_to have_table_row({ "Country" => "🇮🇹 Italy" })
        expect(page).not_to have_table_row({ "Country" => "🇯🇵 Japan" })
        expect(page).to have_table_row({ "Country" => "🇺🇸 United States", "Views" => "3", "Sales" => "1", "Total" => "$5" })
      end

      select "United States", from: "Locations"
      within_table("Locations") do
        expect(page).to have_table_rows_in_order(
          [
            { "State" => "New York", "Views" => "0", "Sales" => "1", "Total" => "$5" },
            { "State" => "California", "Views" => "3", "Sales" => "0", "Total" => "$0" },
          ]
        )
      end
    end

    it "fixes the date range when from is after to" do
      visit sales_dashboard_path(from: "2023-12-14", to: "2023-01-01")
      expect(page).to have_disclosure_button("12/14/2023")
      expect(page).to have_current_path(sales_dashboard_path(from: "2023-12-14", to: "2023-12-14"))
    end

    it "supports quarterly date range selection" do
      visit sales_dashboard_path

      # Get the initial date picker text
      initial_date_picker_text = find('[aria-label="Date range selector"]').text

      # Test "This quarter" option - verify it's available and clickable
      select_disclosure initial_date_picker_text do
        expect(page).to have_content("This quarter")
        click_on "This quarter"
      end

      # Verify the URL parameters changed to quarter dates
      expect(page.current_url).to include("from=")
      expect(page.current_url).to include("to=")

      # Get the new date picker text after selecting "This quarter"
      quarter_date_picker_text = find('[aria-label="Date range selector"]').text

      # Test "Last quarter" option - verify it's available and clickable
      select_disclosure quarter_date_picker_text do
        expect(page).to have_content("Last quarter")
        click_on "Last quarter"
      end

      # Verify the URL parameters changed again for last quarter
      expect(page.current_url).to include("from=")
      expect(page.current_url).to include("to=")

      # Verify the date picker text changed to show the last quarter range
      last_quarter_date_picker_text = find('[aria-label="Date range selector"]').text
      expect(last_quarter_date_picker_text).not_to eq(initial_date_picker_text)
      expect(last_quarter_date_picker_text).not_to eq(quarter_date_picker_text)
    end

    it "handles quarterly date ranges and verifies quarterly options are present" do
      visit sales_dashboard_path

      # Get the initial date picker text
      initial_date_picker_text = find('[aria-label="Date range selector"]').text

      # Verify both quarterly options are available in the dropdown
      select_disclosure initial_date_picker_text do
        expect(page).to have_content("This quarter")
        expect(page).to have_content("Last quarter")

        # Verify other expected options are also present
        expect(page).to have_content("This month")
        expect(page).to have_content("Last month")
        expect(page).to have_content("This year")
        expect(page).to have_content("Last year")

        # Test both quarterly options work
        click_on "This quarter"
      end

      # Verify "This quarter" produces valid URL parameters
      expect(page.current_url).to match(/from=\d{4}-\d{2}-\d{2}/)
      expect(page.current_url).to match(/to=\d{4}-\d{2}-\d{2}/)

      # Get the new date range after "This quarter"
      this_quarter_text = find('[aria-label="Date range selector"]').text

      # Test "Last quarter" option
      select_disclosure this_quarter_text do
        click_on "Last quarter"
      end

      # Verify "Last quarter" produces different valid URL parameters
      expect(page.current_url).to match(/from=\d{4}-\d{2}-\d{2}/)
      expect(page.current_url).to match(/to=\d{4}-\d{2}-\d{2}/)

      # Verify the date range changed
      last_quarter_text = find('[aria-label="Date range selector"]').text
      expect(last_quarter_text).not_to eq(initial_date_picker_text)
      expect(last_quarter_text).not_to eq(this_quarter_text)
    end
  end

  context "with many differrent referrers" do
    let(:product1) { create(:product, user: seller, name: "Product 1") }
    let(:product2) { create(:product, user: seller, name: "Product 2") }

    before do
      recreate_model_index(ProductPageView)

      %w[one two three four five six seven eight nine ten eleven twelve].each do |referrer|
        add_page_view(product1, Time.zone.parse("2023-12-13 12:00:00").iso8601, referrer_domain: referrer)
      end

      3.times { add_page_view(product2, Time.zone.parse("2023-12-16 12:00:00").iso8601, referrer_domain: "one") }
    end

    it "paginates the table" do
      visit sales_dashboard_path(from: "2023-12-01", to: "2023-12-31")

      within_table("Referrer") do
        within(find("tbody")) { expect(page).to have_selector(:table_row, count: 10) }
      end

      click_on "Show more"

      within_table("Referrer") do
        expect(page).to have_table_row({ "Source" => "one", "Views" => "4" })
        %w[two three four five six seven eight nine ten eleven twelve].each do |referrer|
          expect(page).to have_table_row({ "Source" => referrer, "Views" => "1" })
        end
      end

      select_disclosure "Select products..." do
        uncheck "Product 2"
      end

      within_table("Referrer") do
        within(find("tbody")) { expect(page).to have_selector(:table_row, count: 10) }
      end

      click_on "Show more"

      within_table("Referrer") do
        %w[one two three four five six seven eight nine ten].each do |referrer|
          expect(page).to have_table_row({ "Source" => referrer, "Views" => "1" })
        end
      end
    end
  end
end
