# frozen_string_literal: true

class CreateCanadaMonthlySalesReportJob
  include Sidekiq::Job
  include FinanceReportFailureAlert
  sidekiq_options retry: 5, queue: :default, lock: :until_executed, on_conflict: :replace

  def perform(month, year)
    raise ArgumentError, "Invalid month" unless month.in?(1..12)
    raise ArgumentError, "Invalid year" unless year.in?(2014..3200)

    begin
      temp_file = Tempfile.new
      temp_file.write(row_headers.to_csv)

      timeout_seconds = ($redis.get(RedisKey.create_canada_monthly_sales_report_job_max_execution_time_seconds) || 1.hour).to_i
      WithMaxExecutionTime.timeout_queries(seconds: timeout_seconds) do
        starts_at = Date.new(year, month).beginning_of_month.beginning_of_day
        ends_at = Date.new(year, month).end_of_month.end_of_day

        Purchase.successful
          .not_fully_refunded_for_tax_reporting
          .not_chargedback_or_chargedback_reversed
          .where.not(stripe_transaction_id: nil)
          .where("purchases.created_at BETWEEN ? AND ?", starts_at, ends_at)
          .where("(country = 'Canada') OR (country IS NULL AND ip_country = 'Canada')")
          .where("ip_country = 'Canada' OR card_country = 'CA'")
          .where(state: Compliance::Countries.subdivisions_for_select(Compliance::Countries::CAN.alpha2).map(&:first))
          .where(charge_processor_id: [nil, *ChargeProcessor.charge_processor_ids])
          .find_each do |purchase|
          taxjar_info = purchase.purchase_taxjar_info

          price_cents = purchase.price_cents_for_tax_reporting
          fee_cents = purchase.fee_cents_for_tax_reporting
          gumroad_tax_cents = purchase.gumroad_tax_cents_for_tax_reporting
          total_cents = purchase.total_cents_for_tax_reporting

          row = [
            purchase.external_id,
            purchase.created_at.strftime("%m/%d/%Y"),
            ISO3166::Country["CA"].subdivisions[purchase.state]&.name,
            purchase.link.native_type,
            Link::NATIVE_TYPES_TO_TAX_CODE[purchase.link.native_type],
            taxjar_info&.gst_tax_rate,
            taxjar_info&.pst_tax_rate,
            taxjar_info&.qst_tax_rate,
            taxjar_info&.combined_tax_rate,
            Money.new(gumroad_tax_cents).format(no_cents_if_whole: false, symbol: false),
            Money.new(gumroad_tax_cents).format(no_cents_if_whole: false, symbol: false),
            Money.new(price_cents).format(no_cents_if_whole: false, symbol: false),
            Money.new(fee_cents).format(no_cents_if_whole: false, symbol: false),
            Money.new(purchase.shipping_cents).format(no_cents_if_whole: false, symbol: false),
            Money.new(total_cents).format(no_cents_if_whole: false, symbol: false),
            purchase.receipt_url
          ]

          temp_file.write(row.to_csv)
          temp_file.flush
        end

        # Refund leg: refunds issued during the reported month appear as their own negative
        # rows, dated by the refund's date, regardless of when the original purchase happened.
        # The purchase-side filters mirror the sales leg above (minus its date window) so a
        # refund is only reported when its purchase's sale was — or would have been — reported.
        Refund.for_tax_period_reporting(starts_at, ends_at)
          .joins(:purchase)
          .merge(
            Purchase.successful
              .not_chargedback_or_chargedback_reversed
              .where.not(purchases: { stripe_transaction_id: nil })
              .where("(purchases.country = 'Canada') OR (purchases.country IS NULL AND purchases.ip_country = 'Canada')")
              .where("purchases.ip_country = 'Canada' OR purchases.card_country = 'CA'")
              .where(purchases: { state: Compliance::Countries.subdivisions_for_select(Compliance::Countries::CAN.alpha2).map(&:first) })
              .where(purchases: { charge_processor_id: [nil, *ChargeProcessor.charge_processor_ids] })
          )
          .find_each do |refund|
          purchase = refund.purchase
          taxjar_info = purchase.purchase_taxjar_info

          row = [
            purchase.external_id,
            refund.created_at.strftime("%m/%d/%Y"),
            ISO3166::Country["CA"].subdivisions[purchase.state]&.name,
            purchase.link.native_type,
            Link::NATIVE_TYPES_TO_TAX_CODE[purchase.link.native_type],
            taxjar_info&.gst_tax_rate,
            taxjar_info&.pst_tax_rate,
            taxjar_info&.qst_tax_rate,
            taxjar_info&.combined_tax_rate,
            Money.new(-refund.gumroad_tax_cents.to_i).format(no_cents_if_whole: false, symbol: false),
            Money.new(-refund.gumroad_tax_cents.to_i).format(no_cents_if_whole: false, symbol: false),
            Money.new(-refund.amount_cents.to_i).format(no_cents_if_whole: false, symbol: false),
            Money.new(-refund.fee_cents.to_i).format(no_cents_if_whole: false, symbol: false),
            Money.new(0).format(no_cents_if_whole: false, symbol: false),
            Money.new(-refund.total_transaction_cents.to_i).format(no_cents_if_whole: false, symbol: false),
            purchase.receipt_url
          ]

          temp_file.write(row.to_csv)
          temp_file.flush
        end
      end

      temp_file.rewind

      s3_filename = "canada-sales-report-#{year}-#{month}-#{SecureRandom.hex(4)}.csv"
      s3_report_key = "sales-tax/ca-sales-monthly/#{s3_filename}"
      s3_object = Aws::S3::Resource.new.bucket(REPORTING_S3_BUCKET).object(s3_report_key)
      s3_object.upload_file(temp_file)
      s3_signed_url = s3_object.presigned_url(:get, expires_in: 1.week.to_i).to_s

      InternalNotificationWorker.perform_async("payments", "Canada Sales Reporting", "Canada #{year}-#{month} sales report is ready - #{s3_signed_url}", "green")
    ensure
      temp_file.close
    end
  end

  private
    def row_headers
      [
        "Purchase External ID",
        "Purchase Date",
        "Member State of Consumption",
        "Gumroad Product Type",
        "TaxJar Product Tax Code",
        "GST Tax Rate",
        "PST Tax Rate",
        "QST Tax Rate",
        "Combined Tax Rate",
        "Calculated Tax Amount",
        "Tax Collected by Gumroad",
        "Price",
        "Gumroad Fee",
        "Shipping",
        "Total",
        "Receipt URL",
      ]
    end
end
