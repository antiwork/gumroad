# frozen_string_literal: true

# Uploads a single day's taxable US-state order transactions to TaxJar.
#
# Runs DAILY (see config/sidekiq_schedule.yml) so the volume pushed per run is ~1/30th of the
# old month-end bulk push. This is what prevents the recurring month-end failure mode where the
# whole-month push timed out / died mid-run on a transient TaxJar/DNS error and left TaxJar with a
# partial (or zero) month right before its auto-filing window — see the Feb & June 2026 incidents.
#
# The per-purchase selection, ZIP resolution, dollar amounts, and retry/rescue behavior are shared
# with the monthly summary job via UsStateSalesTaxUploader, so daily and monthly stay identical.
# TaxJar order creation is idempotent (an already-imported order is caught and skipped), so a retry
# or an overlap with a manual month re-push is safe.
class UploadUsStatesSalesTaxToTaxjarJob
  include Sidekiq::Job
  include FinanceReportCompletionTracking
  sidekiq_options retry: 5, queue: :default, lock: :until_executed

  # Resolved default for a no-arg scheduled run (mirrors #perform's default). Used to key
  # completion tracking so the backstop can distinguish the scheduled day's upload from a
  # manual re-push of another day/month.
  def self.default_alert_args(reference_time = Time.current)
    [(reference_time.to_date - 1).iso8601]
  end

  sidekiq_retries_exhausted do |job, exception|
    # The scheduler fires with no args (see config/sidekiq_schedule.yml), so job["args"].first is
    # nil for a scheduled run. Mirror #perform's default so the alert email's re-run command is
    # actionable instead of "perform_async(\"\")".
    date = job["args"].first || Date.yesterday.iso8601
    AccountingMailer.us_states_sales_tax_taxjar_upload_failed(
      date, exception.class.name, exception.message
    ).deliver_later
  end

  # date: an ISO8601 date string (defaults to yesterday). Uploads every taxable US order created
  # on that calendar day (UTC) to TaxJar.
  def perform(date = Date.yesterday.iso8601)
    return unless Rails.env.production?

    day = Date.parse(date.to_s)
    subdivision_codes = Compliance::Countries::TAXABLE_US_STATE_CODES

    uploader = UsStateSalesTaxUploader.new(push_to_taxjar: true)
    subdivisions_by_code = UsStateSalesTaxUploader.subdivisions_for(subdivision_codes)
      .index_by(&:code)

    purchase_ids_by_state = UsStateSalesTaxUploader.grouped_purchase_ids_by_state(
      subdivision_codes:,
      starts_at: day.beginning_of_day,
      ends_at: day.end_of_day
    )

    uploaded_count = 0
    purchase_ids_by_state.each do |subdivision_code, purchase_ids|
      subdivision = subdivisions_by_code[subdivision_code]

      purchase_ids.each do |id|
        purchase = Purchase.find(id)
        totals = uploader.upload(purchase:, subdivision:)
        uploaded_count += 1 if totals
      end
    end

    Rails.logger.info("UploadUsStatesSalesTaxToTaxjarJob: uploaded #{uploaded_count} order transactions to TaxJar for #{day.iso8601}")
  end
end
