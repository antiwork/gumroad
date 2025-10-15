# frozen_string_literal: true

class Admin::SalesReport
  include ActiveModel::Model

  YYYY_MM_DD_FORMAT = /\A\d{4}-\d{2}-\d{2}\z/
  INVALID_DATE_FORMAT_MESSAGE = "Invalid date format. Please use YYYY-MM-DD format"

  ACCESSORS = %i[country_code start_date end_date].freeze
  attr_accessor(*ACCESSORS)
  ACCESSORS.each do |accessor|
    define_method("#{accessor}?") do
      public_send(accessor).present?
    end
  end

  validates :country_code, presence: { message: "Please select a country" }
  validates :start_date, presence: { message: INVALID_DATE_FORMAT_MESSAGE }
  validates :end_date, presence: { message: INVALID_DATE_FORMAT_MESSAGE }
  validates :start_date, comparison: { less_than: :end_date, message: "must be before end date", if: %i[start_date? end_date?] }
  validates :start_date, comparison: { less_than_or_equal_to: -> { Date.current }, message: "cannot be in the future", if: :start_date? }

  class << self
    def fetch_job_history
      job_data = $redis.lrange(RedisKey.sales_report_jobs, 0, 19)
      job_data.map { |data| JSON.parse(data) }
    rescue JSON::ParserError
      []
    end
  end

  def generate_later
    job_id = GenerateSalesReportJob.perform_async(
      country_code,
      start_date.to_s,
      end_date.to_s,
      true,
      nil
    )

    store_job_details(job_id)
  end

  def errors_hash
    {
      sales_report: errors.to_hash
    }
  end

  def start_date=(value)
    @start_date = parse_date(value)
  end

  def end_date=(value)
    @end_date = parse_date(value)
  end

  private
    def parse_date(date)
      return date if date.is_a?(Date)
      return if date.blank?
      return unless date.match?(YYYY_MM_DD_FORMAT)

      Date.parse(date)
    rescue Date::Error, ArgumentError
      Rails.logger.warn("Invalid date format: #{date}, set to nil")
      nil
    end

    def store_job_details(job_id)
      job_details = {
        job_id:,
        country_code:,
        start_date: start_date.to_s,
        end_date: end_date.to_s,
        enqueued_at: Time.current.to_s,
        status: "processing"
      }

      $redis.lpush(RedisKey.sales_report_jobs, job_details.to_json)
      $redis.ltrim(RedisKey.sales_report_jobs, 0, 19)
    end
end
