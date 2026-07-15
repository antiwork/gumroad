# frozen_string_literal: true

class GenerateCanadaSalesReportJob
  include Sidekiq::Job
  include FinanceReportFailureAlert
  sidekiq_options retry: 5, queue: :default, lock: :until_executed, on_conflict: :replace

  def perform(month, year)
    raise ArgumentError, "Invalid month" unless month.in?(1..12)
    raise ArgumentError, "Invalid year" unless year.in?(2014..3200)

    begin
      temp_file = Tempfile.new
      temp_file.write(row_headers.to_csv)

      timeout_seconds = ($redis.get(RedisKey.generate_canada_sales_report_job_max_execution_time_seconds) || 1.hour).to_i
      WithMaxExecutionTime.timeout_queries(seconds: timeout_seconds) do
        starts_at = Date.new(year, month).beginning_of_month.beginning_of_day
        ends_at = Date.new(year, month).end_of_month.end_of_day

        Purchase.successful
          .not_fully_refunded_for_tax_reporting
          .not_chargedback_or_chargedback_reversed
          .where.not(stripe_transaction_id: nil)
          .where("purchases.created_at BETWEEN ? AND ?", starts_at, ends_at)
          .find_each do |purchase|
            # Chargebacks keep their existing purchase-flag attribution (the chargeback
            # event-date pass is tracked separately). There is deliberately NO per-row
            # fully-refunded skip here: the not_fully_refunded_for_tax_reporting scope above is
            # the single gate. Any refunded purchase that reaches this loop either reports
            # gross amounts (post-cutover) or has a post-cutover refund row that needs this
            # sale row to offset — re-skipping it here would understate the period pair.
            next if purchase.chargedback_not_reversed?

            country_name, province_name = determine_country_name_and_province_name(purchase)
            next unless country_name == Compliance::Countries::CAN.common_name

            temp_file.write(purchase_row(purchase, country_name, province_name).to_csv)
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
          )
          .find_each do |refund|
            purchase = refund.purchase

            country_name, province_name = determine_country_name_and_province_name(purchase)
            next unless country_name == Compliance::Countries::CAN.common_name

            temp_file.write(refund_row(refund, purchase, country_name, province_name).to_csv)
            temp_file.flush
          end
      end

      temp_file.rewind

      s3_filename = "canada-sales-fees-report-#{year}-#{month}-#{SecureRandom.hex(4)}.csv"
      s3_report_key = "sales-tax/ca-sales-fees-monthly/#{s3_filename}"
      s3_object = Aws::S3::Resource.new.bucket(REPORTING_S3_BUCKET).object(s3_report_key)
      s3_object.upload_file(temp_file)
      s3_signed_url = s3_object.presigned_url(:get, expires_in: 1.week.to_i).to_s

      InternalNotificationWorker.perform_async("payments", "Canada Sales Fees Reporting", "Canada #{year}-#{month} sales fees report is ready - #{s3_signed_url}", "green")
    ensure
      temp_file.close
    end
  end

  private
    def purchase_row(purchase, country_name, province_name)
      [
        purchase.created_at,
        purchase.external_id,
        purchase.seller.external_id,
        purchase.seller.name_or_username,
        purchase.seller.form_email&.gsub(/.{0,4}@/, '####@'),
        country_name,
        province_name,
        purchase.link.external_id,
        purchase.link.name,
        purchase.link.is_recurring_billing? ? "Subscription" : "Product",
        purchase.link.native_type,
        purchase.link.is_physical? ? "Physical" : "Digital",
        purchase.link.is_physical? ? "DTC" : "BS",
        purchase.purchaser&.external_id,
        purchase.purchaser&.name_or_username,
        purchase.email&.gsub(/.{0,4}@/, '####@'),
        purchase.card_visual&.gsub(/.{0,4}@/, '####@'),
        purchase.country.presence || purchase.ip_country,
        buyer_province(purchase),
        purchase.price_cents_for_tax_reporting,
        purchase.fee_cents_for_tax_reporting,
        purchase.was_product_recommended? ? (purchase.price_cents_for_tax_reporting / 10.0).round : 0,
        purchase.tax_cents_for_tax_reporting,
        purchase.gumroad_tax_cents_for_tax_reporting,
        purchase.shipping_cents,
        purchase.total_cents_for_tax_reporting
      ]
    end

    # Same columns as a sale row, with the refund's own date and negated refund amounts, so
    # the refund lands in the month it happened.
    def refund_row(refund, purchase, country_name, province_name)
      refunded_price_cents = refund.amount_cents.to_i

      [
        refund.created_at,
        purchase.external_id,
        purchase.seller.external_id,
        purchase.seller.name_or_username,
        purchase.seller.form_email&.gsub(/.{0,4}@/, '####@'),
        country_name,
        province_name,
        purchase.link.external_id,
        purchase.link.name,
        purchase.link.is_recurring_billing? ? "Subscription" : "Product",
        purchase.link.native_type,
        purchase.link.is_physical? ? "Physical" : "Digital",
        purchase.link.is_physical? ? "DTC" : "BS",
        purchase.purchaser&.external_id,
        purchase.purchaser&.name_or_username,
        purchase.email&.gsub(/.{0,4}@/, '####@'),
        purchase.card_visual&.gsub(/.{0,4}@/, '####@'),
        purchase.country.presence || purchase.ip_country,
        buyer_province(purchase),
        -refunded_price_cents,
        -refund.fee_cents.to_i,
        purchase.was_product_recommended? ? -(refunded_price_cents / 10.0).round : 0,
        -refund.creator_tax_cents.to_i,
        -refund.gumroad_tax_cents.to_i,
        0,
        -refund.total_transaction_cents.to_i
      ]
    end

    def buyer_province(purchase)
      provinces = Compliance::Countries::CAN.subdivisions.values.map(&:code)
      if provinces.include?(purchase.state)
        purchase.state
      else
        provinces.include?(purchase.ip_state) ? purchase.ip_state : "Uncategorized"
      end
    end

    def row_headers
      [
        "Sale time",
        "Sale ID",
        "Seller ID",
        "Seller Name",
        "Seller Email",
        "Seller Country",
        "Seller Province",
        "Product ID",
        "Product Name",
        "Product / Subscription",
        "Product Type",
        "Physical/Digital Product",
        "Direct-To-Customer/Buy-Sell Product",
        "Buyer ID",
        "Buyer Name",
        "Buyer Email",
        "Buyer Card",
        "Buyer Country",
        "Buyer State",
        "Price",
        "Total Gumroad Fee",
        "Gumroad Discover Fee",
        "Creator Sales Tax",
        "Gumroad Sales Tax",
        "Shipping",
        "Total"
      ]
    end

    def determine_country_name_and_province_name(purchase)
      user_compliance_info = purchase.seller.user_compliance_infos.where("created_at < ?", purchase.created_at).where.not("country IS NULL AND business_country IS NULL").last rescue nil
      country_name = user_compliance_info&.legal_entity_country.presence
      province_code = user_compliance_info&.legal_entity_state.presence

      unless country_name.present?
        country_name = purchase.seller&.country
        province_code = purchase.seller&.state
      end

      unless country_name.present?
        country_name = GeoIp.lookup(purchase.seller&.account_created_ip)&.country_name
        province_code = GeoIp.lookup(purchase.seller&.account_created_ip)&.region_name
      end

      country_name = Compliance::Countries.find_by_name(country_name)&.common_name || "Uncategorized"
      province_name = Compliance::Countries::CAN.subdivisions.values.find { |subdivision| subdivision.code == province_code  }&.name || "Uncategorized"

      [country_name, province_name]
    end
end
