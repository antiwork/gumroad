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

      # shows no jobs message
      expect(page).to have_text("Generate your first sales report")
      expect(page).to have_text("Create a report to view sales data by country for a specified date range.")

      # shows new report button
      expect(page).to have_button("New report")
    end

    context "when there are no jobs in history" do
      it "shows no jobs message" do
        allow($redis).to receive(:lrange).and_return([])

        visit admin_sales_reports_path

        expect(page).to have_text("Generate your first sales report")
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
            sales_type: "all_sales",
            enqueued_at: Time.current.to_s,
            status: "processing"
          }.to_json,
          {
            job_id: "124",
            country_code: "JP",
            start_date: "2023-01-01",
            end_date: "2023-06-30",
            sales_type: "discover_sales",
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
        expect(page).to have_text("2023-01-01 - 2023-03-31")
        expect(page).to have_text("All sales")
        expect(page).to have_text("Processing")
        expect(page).to have_text("Japan")
        expect(page).to have_text("2023-01-01 - 2023-06-30")
        expect(page).to have_text("Discover sales")
        expect(page).to have_text("Processing")
      end
    end

    context "when a processing job completes" do
      it "automatically updates the UI to show the download link" do
        processing_job = {
          job_id: "123",
          country_code: "GB",
          start_date: "2023-01-01",
          end_date: "2023-03-31",
          sales_type: "all_sales",
          enqueued_at: Time.current.to_s,
          status: "processing"
        }

        completed_job = processing_job.merge(
          status: "completed",
          download_url: "https://example.com/report.csv"
        )

        allow($redis).to receive(:lrange).with(RedisKey.sales_report_jobs, 0, 19).and_return([processing_job.to_json], [completed_job.to_json])

        visit admin_sales_reports_path

        expect(page).to have_text("Processing")
        expect(page).not_to have_link("United Kingdom_all_sales_report_2023-01-01_2023-03-31")

        expect(page).to have_link("United Kingdom_all_sales_report_2023-01-01_2023-03-31", wait: 5)
        expect(page).not_to have_text("Processing")
      end
    end
    context "when a job has failed" do
      it "re-runs the report in place when the re-run button is clicked" do
        failed_job = {
          job_id: "dead_123",
          country_code: "CH",
          start_date: "2026-04-01",
          end_date: "2026-06-30",
          sales_type: "all_sales",
          enqueued_at: Time.current.to_s,
          status: "failed"
        }

        allow($redis).to receive(:lrange).with(RedisKey.sales_report_jobs, 0, 19).and_return([failed_job.to_json], [failed_job.to_json], [failed_job.merge(job_id: "new_jid", status: "processing").to_json])
        allow(GenerateSalesReportJob).to receive(:perform_async).and_return("new_jid")
        allow($redis).to receive(:eval).and_return(1)
        allow($redis).to receive(:lpush)
        allow($redis).to receive(:ltrim)

        visit admin_sales_reports_path

        expect(page).to have_text("Failed")

        click_on "Re-run"

        # The POST re-renders job_history (mocked to now return the same entry
        # swapped back to processing); Capybara's wait on this assertion also
        # guarantees the request finished before we check the enqueue below.
        expect(page).to have_text("Processing")

        # The re-run reuses the failed row's own parameters, so the admin does
        # not have to re-enter country/date range/type in the form.
        expect(GenerateSalesReportJob).to have_received(:perform_async)
          .with("CH", "2026-04-01", "2026-06-30", "all_sales", true, nil)

        # The entry is swapped in place (LSET via the Lua script), not
        # prepended as a new row on top of the failed one.
        expect($redis).to have_received(:eval)
          .with(Admin::SalesReport::REPLACE_ENTRY_SCRIPT, keys: [RedisKey.sales_report_jobs], argv: [failed_job.to_json, anything])
        expect($redis).not_to have_received(:lpush)
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
      select "All sales", from: "sales_report[sales_type]"
      click_button "Generate"

      wait_for_ajax

      expect(GenerateSalesReportJob).to have_enqueued_sidekiq_job(
        "GB",
        "2023-01-01",
        "2023-03-31",
        GenerateSalesReportJob::ALL_SALES,
        true,
        nil
      )
      expect(page).to have_text("Sales report job enqueued successfully!")
    end
  end
end
