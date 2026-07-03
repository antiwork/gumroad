# frozen_string_literal: true

class CreateUsStatesSalesSummaryReportJob
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :default, lock: :until_executed

  sidekiq_retries_exhausted do |job, exception|
    subdivision_codes, month, year = job["args"]
    AccountingMailer.us_states_sales_summary_report_failed(
      subdivision_codes, month, year, exception.class.name, exception.message
    ).deliver_later
  end

  # push_to_taxjar defaults to false: TaxJar order transactions are now uploaded DAILY by
  # UploadUsStatesSalesTaxToTaxjarJob, so the monthly run only summarizes. Pass true to also
  # (idempotently) push — used for manual backfill / re-push of a month.
  def perform(subdivision_codes, month, year, push_to_taxjar = false)
    raise ArgumentError, "Invalid month" unless month.in?(1..12)
    raise ArgumentError, "Invalid year" unless year.in?(2014..3200)

    uploader = UsStateSalesTaxUploader.new(push_to_taxjar:)

    row_headers = [
      "State",
      "GMV",
      "Number of orders",
      "Sales tax collected"
    ]

    purchase_ids_by_state = UsStateSalesTaxUploader.grouped_purchase_ids_by_state(
      subdivision_codes:,
      starts_at: Date.new(year, month).beginning_of_month.beginning_of_day,
      ends_at: Date.new(year, month).end_of_month.end_of_day
    )

    begin
      temp_file = Tempfile.new
      temp_file.write(row_headers.to_csv)

      purchase_ids_by_state.each do |subdivision_code, purchase_ids|
        next if purchase_ids.empty?

        subdivision = Compliance::Countries::USA.subdivisions[subdivision_code]
        gmv_cents = 0
        order_count = 0
        tax_collected_cents = 0

        purchase_ids.each do |id|
          purchase = Purchase.find(id)

          totals = uploader.upload(purchase:, subdivision:)
          next unless totals

          gmv_cents += totals[:gmv_cents]
          order_count += 1
          tax_collected_cents += totals[:tax_cents]
        end

        temp_file.write([
          subdivision.name,
          Money.new(gmv_cents).format(no_cents_if_whole: false, symbol: false),
          order_count,
          Money.new(tax_collected_cents).format(no_cents_if_whole: false, symbol: false)
        ].to_csv)

        temp_file.flush
      end

      temp_file.rewind

      s3_filename = "us-states-sales-tax-summary-#{year}-#{month}-#{SecureRandom.hex(4)}.csv"
      s3_report_key = "sales-tax/summary/#{s3_filename}"
      s3_object = Aws::S3::Resource.new.bucket(REPORTING_S3_BUCKET).object(s3_report_key)
      s3_object.upload_file(temp_file)
      s3_signed_url = s3_object.presigned_url(:get, expires_in: 1.week.to_i).to_s

      InternalNotificationWorker.perform_async("payments", "US Sales Tax Summary Report", "Multi-state summary report for #{year}-#{month} is ready:\n#{s3_signed_url}", "green")
    ensure
      temp_file.close
    end
  end
end
