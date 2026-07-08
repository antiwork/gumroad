# frozen_string_literal: true

class Admin::SalesReport
  include ActiveModel::Model

  YYYY_MM_DD_FORMAT = /\A\d{4}-\d{2}-\d{2}\z/
  INVALID_DATE_FORMAT_MESSAGE = "Invalid date format. Please use YYYY-MM-DD format"

  ACCESSORS = %i[country_code start_date end_date sales_type].freeze
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
  validates_inclusion_of :sales_type, in: GenerateSalesReportJob::SALES_TYPES, message: "Invalid sales type, should be #{GenerateSalesReportJob::SALES_TYPES.join(" or ")}."

  class << self
    def fetch_job_history
      job_data = $redis.lrange(RedisKey.sales_report_jobs, 0, 19)
      jobs = job_data.map { |data| JSON.parse(data) }
      reconcile_dead_jobs!(jobs)
      jobs
    rescue JSON::ParserError
      []
    end

    private
      # A job's history entry is written as "processing" at enqueue time and only
      # flipped to "completed" by the job itself when it finishes. If the Sidekiq
      # process is killed while the job runs (deploy restart, OOM), the job never
      # gets to raise an exception — Sidekiq moves it straight to the Dead set and
      # no failure callback runs — so the entry would read "processing" forever.
      # Reconcile at read time: any "processing" entry whose job ID is in the Dead
      # set is marked "failed", and the correction is persisted back to Redis so
      # the admin page tells the truth about jobs that need re-running.
      def reconcile_dead_jobs!(jobs)
        processing = jobs.select { |job| job["status"] == "processing" }
        return if processing.empty?

        dead_jids = dead_sales_report_jids
        return if dead_jids.empty?

        jobs.each_with_index do |job, index|
          next unless job["status"] == "processing" && dead_jids.include?(job["job_id"])

          # Persist the correction to Redis first, and only then update the copy
          # we're about to render. That way the page never shows a job as "failed"
          # unless Redis agrees — if the write below raises, the entry keeps
          # rendering as "processing" and gets another reconciliation attempt on
          # the next page load.
          $redis.lset(RedisKey.sales_report_jobs, index, job.merge("status" => "failed").to_json)
          job["status"] = "failed"
        end
      rescue Redis::BaseError => e
        # Reconciliation is best-effort: if Redis hiccups mid-correction, render
        # what we have rather than erroring the admin page. Entries corrected
        # before the failure show "failed" (already persisted); the rest keep
        # their stored status and are retried on the next load.
        Rails.logger.warn("Admin::SalesReport dead-job reconciliation failed: #{e.message}")
      end

      # The Dead set can hold thousands of unrelated jobs, and this runs on every
      # admin page poll. Rather than pulling every entry over the wire, ask Redis
      # to pre-filter with a server-side substring scan for this job class, then
      # double-check the class on the (few) matches — the substring match is
      # against the raw job JSON, so it can catch look-alikes.
      def dead_sales_report_jids
        Sidekiq::DeadSet.new.scan("GenerateSalesReportJob")
          .filter_map { |dead_job| dead_job.jid if dead_job.klass == "GenerateSalesReportJob" }
          .to_set
      end
  end

  def generate_later
    job_id = GenerateSalesReportJob.perform_async(
      country_code,
      start_date.to_s,
      end_date.to_s,
      sales_type,
      true,
      nil
    )

    store_job_details(job_id)
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
        sales_type:,
        enqueued_at: Time.current.to_s,
        status: "processing"
      }

      $redis.lpush(RedisKey.sales_report_jobs, job_details.to_json)
      $redis.ltrim(RedisKey.sales_report_jobs, 0, 19)
    end
end
