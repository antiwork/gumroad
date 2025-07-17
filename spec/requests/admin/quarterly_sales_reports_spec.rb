# frozen_string_literal: true

require "spec_helper"

describe "Admin::QuarterlySalesReportsController", type: :feature, js: true do
  let(:admin) { create(:admin_user) }

  before do
    login_as(admin)
  end

  describe "GET /admin/quarterly_sales_reports" do
    it "displays the React sales reports page" do
      visit admin_quarterly_sales_reports_path

      expect(page).to have_text("Sales reports")
      expect(page).to have_text("Enqueue sales report jobs with custom date ranges")
    end

    it "shows country dropdown with full country names" do
      visit admin_quarterly_sales_reports_path

      expect(page).to have_select("quarterly_sales_report[country_code]", with_options: ["United Kingdom", "United States", "Canada"])
    end

    it "shows date input fields" do
      visit admin_quarterly_sales_reports_path

      expect(page).to have_field("quarterly_sales_report[start_date]", placeholder: "YYYY-MM-DD")
      expect(page).to have_field("quarterly_sales_report[end_date]", placeholder: "YYYY-MM-DD")
    end

    it "shows job history section" do
      visit admin_quarterly_sales_reports_path

      expect(page).to have_text("Job history")
    end

    context "when there are no jobs in history" do
      it "shows no jobs message" do
        allow($redis).to receive(:lrange).and_return([])

        visit admin_quarterly_sales_reports_path

        expect(page).to have_text("No jobs enqueued yet.")
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
        allow($redis).to receive(:lrange).with(RedisKey.quarterly_sales_report_jobs, 0, 19).and_return(job_data)
      end

      it "displays job history table" do
        visit admin_quarterly_sales_reports_path

        expect(page).to have_table
        expect(page).to have_text("GB")
        expect(page).to have_text("2023-01-01 to 2023-03-31")
        expect(page).to have_text("processing")
      end
    end
  end

  describe "POST /admin/quarterly_sales_reports" do
    before do
      allow($redis).to receive(:lpush)
      allow($redis).to receive(:ltrim)
    end

    it "enqueues a job when React form is submitted" do
      visit admin_quarterly_sales_reports_path

      select "United Kingdom", from: "quarterly_sales_report[country_code]"
      fill_in "quarterly_sales_report[start_date]", with: "2023-01-01"
      fill_in "quarterly_sales_report[end_date]", with: "2023-03-31"
      click_button "Enqueue report job"

      expect(GenerateQuarterlySalesReportJob).to have_enqueued_sidekiq_job(
        "GB",
        "2023-01-01",
        "2023-03-31",
        true,
        nil
      )
      expect(page).to have_text("Sales report job enqueued successfully!")
    end

    it "submits alpha2 country code even when full name is displayed" do
      visit admin_quarterly_sales_reports_path

      select "Australia", from: "quarterly_sales_report[country_code]"
      fill_in "quarterly_sales_report[start_date]", with: "2023-04-01"
      fill_in "quarterly_sales_report[end_date]", with: "2023-06-30"
      click_button "Enqueue report job"

      expect(GenerateQuarterlySalesReportJob).to have_enqueued_sidekiq_job(
        "AU",
        "2023-04-01",
        "2023-06-30",
        true,
        nil
      )
    end
  end
end
