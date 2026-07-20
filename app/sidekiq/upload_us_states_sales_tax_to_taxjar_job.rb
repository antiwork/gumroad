# frozen_string_literal: true

# Uploads a single day's taxable US-state order and refund transactions to TaxJar.
#
# Runs DAILY (see config/sidekiq_schedule.yml) so the volume pushed per run is ~1/30th of the
# old month-end bulk push. This is what prevents the recurring month-end failure mode where the
# whole-month push timed out / died mid-run on a transient TaxJar/DNS error and left TaxJar with a
# partial (or zero) month right before its auto-filing window — see the Feb & June 2026 incidents.
#
# Orders: every taxable US purchase created on the day. Purchases created on/after
# UsStateSalesTaxUploader::REFUND_REPORTING_CUTOVER are pushed at their gross (as-of-purchase)
# amounts; earlier purchases are pushed with only their pre-cutover refunds netted in, so a
# re-push of a historical day reproduces the numbers that were originally filed (see the
# uploader for the exact boundary).
#
# Refunds: every refund created on the day is pushed as its own TaxJar refund transaction,
# dated by the refund date. This is what credits the refunded tax in the period the refund
# happened — previously a refund issued after its purchase's upload day was never communicated
# to TaxJar at all, so state returns (which TaxJar auto-files from this data) overstated tax
# on every late refund.
#
# The per-purchase selection, ZIP resolution, dollar amounts, and retry/rescue behavior are shared
# with the monthly summary job via UsStateSalesTaxUploader, so daily and monthly stay identical.
# TaxJar order/refund creation is idempotent (an already-imported transaction is caught and
# skipped), so a retry or an overlap with a manual re-push is safe.
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
  # on that calendar day (UTC) to TaxJar, plus every refund created on that day as a refund
  # transaction (post-cutover only — see UsStateSalesTaxUploader::REFUND_REPORTING_CUTOVER).
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

    refund_ids_by_state = UsStateSalesTaxUploader.grouped_refund_ids_by_state(
      subdivision_codes:,
      starts_at: day.beginning_of_day,
      ends_at: day.end_of_day
    )

    uploaded_refund_count = 0
    refund_ids_by_state.each do |subdivision_code, refund_ids|
      subdivision = subdivisions_by_code[subdivision_code]

      refund_ids.each do |id|
        refund = Refund.find(id)
        totals = uploader.upload_refund(refund:, subdivision:)
        uploaded_refund_count += 1 if totals
      end
    end

    # Chargeback legs: disputes formalized on the day are pushed as refund transactions dated
    # by the dispute event date (purchases.chargeback_date), and disputes won on the day are
    # pushed as re-add order transactions dated by the Dispute row's won_at. This replaces the
    # old silent treatment where a charged-back purchase's order simply vanished on any
    # re-push — deleting gross from a period whose return may already have been auto-filed.
    # Only event-dated (post-cutover) chargebacks get legs; see
    # Purchase::Reportable::CHARGEBACK_REPORTING_CUTOVER.
    chargeback_ids_by_state = UsStateSalesTaxUploader.grouped_chargeback_purchase_ids_by_state(
      subdivision_codes:,
      starts_at: day.beginning_of_day,
      ends_at: day.end_of_day
    )

    uploaded_chargeback_count = 0
    chargeback_ids_by_state.each do |subdivision_code, purchase_ids|
      subdivision = subdivisions_by_code[subdivision_code]

      purchase_ids.each do |id|
        purchase = Purchase.find(id)
        totals = uploader.upload_chargeback(purchase:, subdivision:)
        uploaded_chargeback_count += 1 if totals
      end
    end

    reversal_ids_by_state = UsStateSalesTaxUploader.grouped_chargeback_reversal_purchase_ids_by_state(
      subdivision_codes:,
      starts_at: day.beginning_of_day,
      ends_at: day.end_of_day
    )

    uploaded_reversal_count = 0
    reversal_ids_by_state.each do |subdivision_code, purchase_ids|
      subdivision = subdivisions_by_code[subdivision_code]

      purchase_ids.each do |id|
        purchase = Purchase.find(id)
        # The window is re-passed so the uploader only emits the leg when the purchase's
        # canonical reversal date actually falls on this day (a purchase with several dispute
        # rows can be selected by a non-canonical row's won_at — see the uploader).
        totals = uploader.upload_chargeback_reversal(
          purchase:, subdivision:,
          starts_at: day.beginning_of_day, ends_at: day.end_of_day
        )
        uploaded_reversal_count += 1 if totals
      end
    end

    Rails.logger.info(
      "UploadUsStatesSalesTaxToTaxjarJob: uploaded #{uploaded_count} order, #{uploaded_refund_count} refund, " \
      "#{uploaded_chargeback_count} chargeback, and #{uploaded_reversal_count} chargeback-reversal transactions " \
      "to TaxJar for #{day.iso8601}"
    )
  end
end
