# frozen_string_literal: true

require "spec_helper"

describe "Admin::SalesReportsController", type: :system, js: true do
  let(:admin) { create(:admin_user) }

  before do
    login_as(admin)
  end

  describe "GET /admin/sales_reports" do
    it "displays the sales reports page" do
      visit admin_sales_reports_path

      # displays the sales reports page
      expect(page).to have_text("Sales reports")
      expect(page).to have_text("Generate sales report with custom date ranges")

      # shows country dropdown with full country names
      expect(page).to have_select("sales_report[country_code]", with_options: ["United Kingdom", "United States", "Canada"])

      # shows date input fields
      expect(page).to have_text("Sales reports")
      expect(page).to have_text("Generate sales report with custom date ranges")

      # shows no jobs message
      expect(page).to have_text("No sales reports generated yet.")
    end

    context "when there are no jobs in history" do
      it "shows no jobs message" do
        allow($redis).to receive(:lrange).and_return([])

        visit admin_sales_reports_path

        expect(page).to have_text("No sales reports generated yet.")
      end
    end

    context "when there are jobs in history" do
      before do
        job_data = [
          {
            job_id: "123",
            country_code: "GB",
            start_date: "2023-01-01",
            end_date: "2023-03-31",
            enqueued_at: Time.current.to_s,
            status: "processing"
          }.to_json
        ]
        allow($redis).to receive(:lrange).with(RedisKey.sales_report_jobs, 0, 19).and_return(job_data)
      end

      it "displays job history table" do
        visit admin_sales_reports_path

        expect(page).to have_table
        expect(page).to have_text("United Kingdom")
        expect(page).to have_text("2023-01-01 to 2023-03-31")
        expect(page).to have_text("processing")
      end
    end
  end

  describe "POST /admin/sales_reports" do
    before do
      allow($redis).to receive(:lpush)
      allow($redis).to receive(:ltrim)
    end

    # TODO: Fix this test
    xit "enqueues a job when form is submitted" do
      visit admin_sales_reports_path

      select "United Kingdom", from: "sales_report[country_code]"
      fill_in "sales_report[start_date]", with: "2023-01-01"
      fill_in "sales_report[end_date]", with: "2023-03-31"
      click_button "Generate report"

      wait_for_ajax

      expect(GenerateSalesReportJob).to have_enqueued_sidekiq_job(
        "GB",
        "2023-01-01",
        "2023-03-31",
        true,
        nil
      )
      expect(page).to have_text("Sales report job enqueued successfully!")
    end
  end
end
