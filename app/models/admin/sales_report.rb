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

  # How many recent Dead-set entries we are willing to read when looking for
  # dead sales report jobs, and how long the result may be reused across page
  # loads. Both exist to keep reconciliation cheap: the admin page polls every
  # few seconds while a report is running, and the Dead set in production can
  # hold hundreds of thousands of unrelated jobs.
  DEAD_SET_SCAN_LIMIT = 1_000
  DEAD_JIDS_CACHE_TTL = 1.minute
  DEAD_JIDS_CACHE_KEY = "admin/sales_report/dead_jids/v1"

  # Finds the history entry whose current value is exactly ARGV[1] and swaps it
  # for ARGV[2], atomically. Matching by value (not by a previously computed
  # index) means a concurrent LPUSH of a new report, or the job completing and
  # rewriting its own entry, can never cause us to overwrite the wrong entry:
  # if the stored value changed since we read it, LPOS finds nothing and we
  # leave the list alone. Used both to mark dead jobs as failed and to swap a
  # failed entry back to "processing" when it is re-run in place.
  REPLACE_ENTRY_SCRIPT = <<~LUA
    local index = redis.call('LPOS', KEYS[1], ARGV[1])
    if index then
      redis.call('LSET', KEYS[1], index, ARGV[2])
      return 1
    end
    return 0
  LUA

  class << self
    def fetch_job_history
      raw_entries = $redis.lrange(RedisKey.sales_report_jobs, 0, 19)
      jobs = raw_entries.map { |data| JSON.parse(data) }
      reconcile_dead_jobs!(jobs, raw_entries)
      jobs
    rescue JSON::ParserError
      []
    end

    # Re-runs the failed history entry identified by job_id without adding a
    # new row: a fresh Sidekiq job is enqueued with the entry's own parameters,
    # and the entry itself is swapped back to "processing" (with the new job ID
    # and enqueue time) in place. Returns true when the entry was swapped, nil
    # when no failed entry with that job ID exists — e.g. it already completed,
    # was re-run from another tab, or fell off the 20-entry history.
    def rerun_failed(job_id)
      raw_entry = $redis.lrange(RedisKey.sales_report_jobs, 0, 19).find do |data|
        entry = JSON.parse(data) rescue nil
        entry && entry["job_id"] == job_id && entry["status"] == "failed"
      end
      return unless raw_entry

      entry = JSON.parse(raw_entry)
      new_job_id = GenerateSalesReportJob.perform_async(
        entry["country_code"],
        entry["start_date"],
        entry["end_date"],
        entry["sales_type"],
        true,
        nil
      )
      updated_entry = entry.merge(
        "job_id" => new_job_id,
        "enqueued_at" => Time.current.to_s,
        "status" => "processing"
      ).to_json

      # Value-matched swap (see REPLACE_ENTRY_SCRIPT): if the stored entry
      # changed between our read and now (concurrent re-run from another tab,
      # completion writer), the swap is skipped. The new job is already
      # enqueued at that point, so fall back to prepending its entry rather
      # than losing track of a running job.
      swapped = $redis.eval(REPLACE_ENTRY_SCRIPT, keys: [RedisKey.sales_report_jobs], argv: [raw_entry, updated_entry])
      if swapped != 1
        $redis.lpush(RedisKey.sales_report_jobs, updated_entry)
        $redis.ltrim(RedisKey.sales_report_jobs, 0, 19)
      end
      true
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
      def reconcile_dead_jobs!(jobs, raw_entries)
        processing = jobs.select { |job| job["status"] == "processing" }
        return if processing.empty?

        dead_jids = dead_sales_report_jids(processing)
        return if dead_jids.empty?

        jobs.each_with_index do |job, index|
          next unless job["status"] == "processing" && dead_jids.include?(job["job_id"])

          # Persist the correction to Redis first, and only then update the copy
          # we're about to render. The Lua script only writes if the entry still
          # holds the exact value we read (see REPLACE_ENTRY_SCRIPT), so a stale
          # read can't clobber a concurrent update — in that case the entry keeps
          # rendering with its stored status and gets another reconciliation
          # attempt on the next page load.
          updated_entry = job.merge("status" => "failed").to_json
          swapped = $redis.eval(REPLACE_ENTRY_SCRIPT, keys: [RedisKey.sales_report_jobs], argv: [raw_entries[index], updated_entry])
          job["status"] = "failed" if swapped == 1
        end
      rescue Redis::BaseError, RedisClient::Error => e
        # Reconciliation is best-effort: if either Redis (the app's $redis or
        # Sidekiq's, which raises RedisClient errors) hiccups mid-correction,
        # render what we have rather than erroring the admin page. Entries
        # corrected before the failure show "failed" (already persisted); the
        # rest keep their stored status and are retried on the next load.
        Rails.logger.warn("Admin::SalesReport dead-job reconciliation failed (#{e.class}): #{e.message} jids=#{processing.map { _1["job_id"] }.join(",")}")
      end

      # The Dead set is a sorted set scored by the time each job died, so
      # instead of scanning all of it (it can hold hundreds of thousands of
      # unrelated jobs) we only read jobs that died after the oldest
      # still-"processing" history entry was enqueued — nothing older can
      # belong to an entry we are reconciling. The result is cached briefly
      # because the admin page polls every few seconds while a report runs,
      # and the answer rarely changes between polls. A job that is retried
      # from the Dead set within the cache window can be briefly re-marked
      # "failed"; the completion writer accepts "failed" entries, so a
      # successful retry still flips the entry to "completed".
      def dead_sales_report_jids(processing_entries)
        Rails.cache.fetch(DEAD_JIDS_CACHE_KEY, expires_in: DEAD_JIDS_CACHE_TTL) do
          oldest_enqueued_at = processing_entries.filter_map { |job| Time.zone.parse(job["enqueued_at"].to_s) rescue nil }.min
          min_score = (oldest_enqueued_at || 30.days.ago).to_f

          dead_payloads = Sidekiq.redis do |connection|
            # ZRANGE with the BYSCORE option is the modern form of the old
            # ZRANGEBYSCORE command, which was removed in Redis 8.0. Sidekiq 7
            # already requires Redis 6.2+, where both forms exist, so this works
            # across every Redis version we can be running against.
            connection.call("ZRANGE", "dead", min_score, "+inf", "BYSCORE", "LIMIT", 0, DEAD_SET_SCAN_LIMIT)
          end

          dead_payloads.filter_map do |payload|
            dead_job = JSON.parse(payload)
            dead_job["jid"] if dead_job["class"] == "GenerateSalesReportJob"
          rescue JSON::ParserError
            nil
          end.to_set
        end
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
