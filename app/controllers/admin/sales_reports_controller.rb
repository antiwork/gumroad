# frozen_string_literal: true

class Admin::SalesReportsController < Admin::BaseController
  def index
    @title = "Sales reports"

    render inertia: "Admin/SalesReports/Index", props: {
      countries: Compliance::Countries.for_select.map { |alpha2, name| [name, alpha2] },
      job_history: fetch_job_history
    }
  end

  def create
    country_code = params[:sales_report][:country_code]
    start_date_str = params[:sales_report][:start_date]
    end_date_str = params[:sales_report][:end_date]

    errors = { sales_report: {} }
    errors[:sales_report][:country_code] = "Please select a country" if country_code.blank?
    errors[:sales_report][:start_date] = "Invalid date format. Please use YYYY-MM-DD format" if start_date_str.blank?
    errors[:sales_report][:end_date] = "Invalid date format. Please use YYYY-MM-DD format" if end_date_str.blank?

    start_date = Date.parse(start_date_str)
    end_date = Date.parse(end_date_str)

    errors[:sales_report][:start_date] = "Start date must be before end date" if start_date > end_date
    errors[:sales_report][:start_date] = "Start date cannot be in the future" if start_date > Date.current

    return redirect_to admin_sales_reports_path, inertia: { errors: errors }, alert: "Invalid form submission. Please fix the errors." if errors[:sales_report].any?

    job_id = GenerateSalesReportJob.perform_async(
      country_code,
      start_date.to_s,
      end_date.to_s,
      true,
      nil
    )

    store_job_details(job_id, country_code, start_date, end_date)

    redirect_to admin_sales_reports_path, status: :see_other, notice: "Sales report job enqueued successfully!"
  end

  private
    def fetch_job_history
      job_data = $redis.lrange(RedisKey.sales_report_jobs, 0, 19)
      job_data.map { |data| JSON.parse(data) }
    rescue JSON::ParserError
      []
    end

    def store_job_details(job_id, country_code, start_date, end_date)
      job_details = {
        job_id: job_id,
        country_code: country_code,
        start_date: start_date.to_s,
        end_date: end_date.to_s,
        enqueued_at: Time.current.to_s,
        status: "processing"
      }

      $redis.lpush(RedisKey.sales_report_jobs, job_details.to_json)
      $redis.ltrim(RedisKey.sales_report_jobs, 0, 19)
    end
end
