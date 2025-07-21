# frozen_string_literal: true

class CreateIndiaSalesReportJob
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :default, lock: :until_executed, on_conflict: :replace

  VALID_INDIAN_STATES = %w[
    AP AR AS BR CG GA GJ HR HP JK JH KA
    KL MP MH MN ML MZ NL OR PB RJ SK TN
    TR UK UP WB
    AN CH DH DD DL LD PY
  ].to_set.freeze

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
          next if purchase.stripe_refunded == true

          price_cents = purchase.price_cents
          tax_amount_cents = purchase.gumroad_tax_cents || 0

          raw_state = (purchase.ip_state || "").strip.upcase
          display_state = if raw_state.match?(/^\d+$/) || !VALID_INDIAN_STATES.include?(raw_state)
            ""
          else
            raw_state
          end

          expected_tax_rounded = (price_cents * india_tax_rate).round
          expected_tax_floored = (price_cents * india_tax_rate).floor
          diff_rounded = expected_tax_rounded - tax_amount_cents
          diff_floored = expected_tax_floored - tax_amount_cents

          calc_tax_rate = if price_cents > 0 && tax_amount_cents > 0
            (BigDecimal(tax_amount_cents.to_s) / BigDecimal(price_cents.to_s) * 100).round(4).to_f
          else
            0
          end

          row = [
            purchase.external_id,
            purchase.created_at.strftime("%Y-%m-%d"),
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

          temp_file.write(row.to_csv)
          temp_file.flush
        end
      end

      temp_file.rewind
      s3_object = Aws::S3::Resource.new.bucket(REPORTING_S3_BUCKET).object(s3_report_key)
      s3_object.upload_file(temp_file)
      s3_signed_url = s3_object.presigned_url(:get, expires_in: 1.week.to_i).to_s

      SlackMessageWorker.perform_async("payments", "India Sales Reporting", "India #{year}-#{month.to_s.rjust(2, '0')} sales report is ready - #{s3_signed_url}", "green")
    ensure
      temp_file.close
    end
  end

  private
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
