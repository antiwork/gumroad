# frozen_string_literal: true

class Admin::SalesReportsController < Admin::BaseController
  before_action :set_react_component_props, only: [:index]

  def index
    @title = "Sales reports"
  end

  def create
    country_code = params[:sales_report][:country_code]
    start_date_str = params[:sales_report][:start_date]
    end_date_str = params[:sales_report][:end_date]

    # Validate country code
    if country_code.blank?
      return render json: { message: "Please select a country" }, status: :unprocessable_entity
    end

    unless ISO3166::Country[country_code]
      return render json: { message: "Invalid country code" }, status: :unprocessable_entity
    end

    # Validate and parse dates
    begin
      start_date = Date.parse(start_date_str)
      end_date = Date.parse(end_date_str)
    rescue Date::Error, ArgumentError
      return render json: { message: "Invalid date format. Please use YYYY-MM-DD format" }, status: :unprocessable_entity
    end

    # Validate date range
    if start_date > end_date
      return render json: { message: "Start date must be before end date" }, status: :unprocessable_entity
    end

    if start_date > Date.current
      return render json: { message: "Start date cannot be in the future" }, status: :unprocessable_entity
    end

    job_id = GenerateSalesReportJob.perform_async(
      country_code,
      start_date.to_s,
      end_date.to_s,
      true,
      nil
    )

    store_job_details(job_id, country_code, start_date, end_date)

    render json: { success: true, message: "Sales report job enqueued successfully!" }
  end

  private
    def set_react_component_props
      @react_component_props = {
        title: "Sales reports",
        countries: Compliance::Countries.for_select.map { |alpha2, name| [name, alpha2] },
        job_history: fetch_job_history,
        form_action: admin_sales_reports_path,
        authenticity_token: form_authenticity_token
      }
    end

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
