# frozen_string_literal: true

class Admin::QuarterlySalesReportsController < Admin::BaseController
  def index
    @title = "Quarterly sales reports"
    @countries = [
      ["GB", "United Kingdom"],
      ["AU", "Australia"], 
      ["SG", "Singapore"],
      ["NO", "Norway"]
    ]
    @job_history = fetch_job_history
  end

  def create
    country_code = params[:quarterly_sales_report][:country_code]
    start_date = Date.parse(params[:quarterly_sales_report][:start_date])
    end_date = Date.parse(params[:quarterly_sales_report][:end_date])
    
    job_id = GenerateQuarterlySalesReportJob.perform_async(
      country_code, 
      nil,
      nil,
      true,
      nil,
      start_date,
      end_date
    )
    
    store_job_details(job_id, country_code, start_date, end_date)
    
    redirect_to admin_quarterly_sales_reports_path, notice: "Quarterly sales report job enqueued successfully!"
  end

  private

  def fetch_job_history
    job_data = $redis.lrange(RedisKey.quarterly_sales_report_jobs, 0, 19)
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
    
    $redis.lpush(RedisKey.quarterly_sales_report_jobs, job_details.to_json)
    $redis.ltrim(RedisKey.quarterly_sales_report_jobs, 0, 19)
  end
end
