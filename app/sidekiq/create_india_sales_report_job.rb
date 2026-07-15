# frozen_string_literal: true

class CreateIndiaSalesReportJob
  include Sidekiq::Job
  include FinanceReportFailureAlert
  sidekiq_options retry: 5, queue: :default, lock: :until_executed, on_conflict: :replace

  # The scheduler fires with no args; pin the resolved period in the exhaustion alert so a
  # late re-run reports the month the failed run was for (not whatever "last month" is then).
  def self.default_alert_args(reference_time = Time.current)
    previous_month = reference_time.last_month
    [previous_month.month, previous_month.year]
  end

  def perform(month = nil, year = nil)
    if month.nil? || year.nil?
      previous_month = 1.month.ago
      month ||= previous_month.month
      year ||= previous_month.year
    end

    raise ArgumentError, "Invalid month" unless month.in?(1..12)
    raise ArgumentError, "Invalid year" unless year.in?(2014..3200)

    s3_filename = "india-sales-report-#{year}-#{month.to_s.rjust(2, '0')}-#{SecureRandom.hex(4)}.csv"
    s3_report_key = "sales-tax/in-sales-monthly/#{s3_filename}"

    begin
      temp_file = Tempfile.new
      temp_file.write(row_headers.to_csv)

      start_date = Date.new(year, month).beginning_of_month.beginning_of_day
      end_date = Date.new(year, month).end_of_month.end_of_day

      india_tax_rate = ZipTaxRate.where(country: "IN", state: nil, user_id: nil).alive.last.combined_rate
      india_tax_rate_percentage = (india_tax_rate * 100).to_i

      timeout_seconds = ($redis.get("create_india_sales_report_job_max_execution_time_seconds") || 1.hour).to_i
      WithMaxExecutionTime.timeout_queries(seconds: timeout_seconds) do
        Purchase.joins("LEFT JOIN purchase_sales_tax_infos ON purchases.id = purchase_sales_tax_infos.purchase_id")
                .where("purchase_state != 'failed'")
                .where.not(stripe_transaction_id: nil)
                .where(created_at: start_date..end_date)
                .where("(country = 'India') OR (country IS NULL AND ip_country = 'India') OR (card_country = 'IN')")
                .where("price_cents > 0")
                .where("purchase_sales_tax_infos.business_vat_id IS NULL OR purchase_sales_tax_infos.business_vat_id = ''")
                .find_each do |purchase|
          next if purchase.chargeback_date.present? && !purchase.chargeback_reversed?
          # A refund used to drop the purchase's row entirely, no matter when the refund
          # happened — restating a filed month if it was ever re-generated, and never reporting
          # the refund in its own period. Pre-cutover refunded purchases keep that treatment so
          # historical months regenerate as filed; post-cutover purchases stay in the report at
          # gross amounts, and the refund rows below are what offset them.
          next if purchase.stripe_refunded == true && !purchase.gross_amounts_for_tax_reporting?

          temp_file.write(purchase_row(purchase, india_tax_rate, india_tax_rate_percentage).to_csv)
          temp_file.flush
        end

        # Refund leg: refunds issued during the reported month appear as their own negative
        # rows, dated by the refund's date, regardless of when the original purchase happened.
        # The purchase-side filters mirror the sales leg above (minus its date window) so a
        # refund is only reported when its purchase's sale was — or would have been — reported.
        Refund.for_tax_period_reporting(start_date, end_date)
          .joins(:purchase)
          .joins("LEFT JOIN purchase_sales_tax_infos ON purchases.id = purchase_sales_tax_infos.purchase_id")
          .where.not(purchases: { purchase_state: "failed" })
          .where.not(purchases: { stripe_transaction_id: nil })
          .where("(purchases.country = 'India') OR (purchases.country IS NULL AND purchases.ip_country = 'India') OR (purchases.card_country = 'IN')")
          .where("purchases.price_cents > 0")
          .where("purchase_sales_tax_infos.business_vat_id IS NULL OR purchase_sales_tax_infos.business_vat_id = ''")
          .find_each do |refund|
          purchase = refund.purchase
          next if purchase.chargeback_date.present? && !purchase.chargeback_reversed?

          temp_file.write(refund_row(refund, purchase, india_tax_rate, india_tax_rate_percentage).to_csv)
          temp_file.flush
        end
      end

      temp_file.rewind
      s3_object = Aws::S3::Resource.new.bucket(REPORTING_S3_BUCKET).object(s3_report_key)
      s3_object.upload_file(temp_file)
      s3_signed_url = s3_object.presigned_url(:get, expires_in: 1.week.to_i).to_s

      InternalNotificationWorker.perform_async("payments", "India Sales Reporting", "India #{year}-#{month.to_s.rjust(2, '0')} sales report is ready - #{s3_signed_url}", "green")
    ensure
      temp_file.close
    end
  end

  private
    def purchase_row(purchase, india_tax_rate, india_tax_rate_percentage)
      india_report_row(
        purchase:,
        row_date: purchase.created_at,
        price_cents: purchase.price_cents,
        tax_amount_cents: purchase.gumroad_tax_cents || 0,
        india_tax_rate:,
        india_tax_rate_percentage:
      )
    end

    # Same columns as a sale row, with the refund's own date and negated refund amounts, so
    # the refund lands in the month it happened.
    def refund_row(refund, purchase, india_tax_rate, india_tax_rate_percentage)
      india_report_row(
        purchase:,
        row_date: refund.created_at,
        price_cents: -refund.amount_cents.to_i,
        tax_amount_cents: -refund.gumroad_tax_cents.to_i,
        india_tax_rate:,
        india_tax_rate_percentage:
      )
    end

    def india_report_row(purchase:, row_date:, price_cents:, tax_amount_cents:, india_tax_rate:, india_tax_rate_percentage:)
      raw_state = (purchase.ip_state || "").strip.upcase
      display_state = Compliance::Countries.valid_indian_state?(raw_state) ? raw_state : ""

      expected_tax_rounded = (price_cents * india_tax_rate).round
      expected_tax_floored = (price_cents * india_tax_rate).floor
      diff_rounded = expected_tax_rounded - tax_amount_cents
      diff_floored = expected_tax_floored - tax_amount_cents

      # The rate check compares magnitudes, so it works the same for negative refund rows.
      calc_tax_rate = if price_cents != 0 && tax_amount_cents != 0
        (BigDecimal(tax_amount_cents.to_s) / BigDecimal(price_cents.to_s) * 100).round(4).to_f
      else
        0
      end

      [
        purchase.external_id,
        row_date.strftime("%Y-%m-%d"),
        display_state,
        india_tax_rate_percentage,
        price_cents,
        tax_amount_cents,
        calc_tax_rate,
        expected_tax_rounded,
        expected_tax_floored,
        diff_rounded,
        diff_floored
      ]
    end

    def row_headers
      [
        "ID",
        "Date",
        "Place of Supply (State)",
        "Zip Tax Rate (%) (Rate from Database)",
        "Taxable Value (cents)",
        "Integrated Tax Amount (cents)",
        "Tax Rate (%) (Calculated From Tax Collected)",
        "Expected Tax (cents, rounded)",
        "Expected Tax (cents, floored)",
        "Tax Difference (rounded)",
        "Tax Difference (floored)"
      ]
    end
end
