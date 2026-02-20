# frozen_string_literal: true

class CreateGlobalSalesTaxSummaryReportJob
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :default, lock: :until_executed

  def perform(month, year)
    raise ArgumentError, "Invalid month" unless month.in?(1..12)
    raise ArgumentError, "Invalid year" unless year.in?(2014..3200)

    start_date = Date.new(year, month).beginning_of_month.beginning_of_day
    end_date = Date.new(year, month).end_of_month.end_of_day

    aggregation = Hash.new { |h, k| h[k] = { gmv_cents: 0, order_count: 0, tax_collected_cents: 0 } }

    timeout_seconds = ($redis.get(RedisKey.create_global_sales_tax_summary_report_job_max_execution_time_seconds) || 1.hour).to_i
    WithMaxExecutionTime.timeout_queries(seconds: timeout_seconds) do
      Purchase.successful
        .not_fully_refunded
        .not_chargedback_or_chargedback_reversed
        .where.not(stripe_transaction_id: nil)
        .where("gumroad_tax_cents > 0")
        .where("purchases.created_at BETWEEN ? AND ?", start_date, end_date)
        .where(charge_processor_id: [nil, *ChargeProcessor.charge_processor_ids])
        .find_each do |purchase|
        country_name = resolve_country_name(purchase)
        state_code = resolve_state(purchase, country_name)

        key = [country_name, state_code]
        aggregation[key][:gmv_cents] += purchase.total_cents_net_of_refunds
        aggregation[key][:order_count] += 1
        aggregation[key][:tax_collected_cents] += purchase.gumroad_tax_cents_net_of_refunds
      end
    end

    row_headers = ["Country", "State/Province", "GMV", "Number of orders", "Sales tax collected"]

    begin
      temp_file = Tempfile.new
      temp_file.write(row_headers.to_csv)

      aggregation.keys.sort.each do |key|
        country_name, state_code = key
        data = aggregation[key]

        temp_file.write([
          country_name,
          state_code,
          Money.new(data[:gmv_cents]).format(no_cents_if_whole: false, symbol: false),
          data[:order_count],
          Money.new(data[:tax_collected_cents]).format(no_cents_if_whole: false, symbol: false)
        ].to_csv)
      end

      temp_file.flush
      temp_file.rewind

      s3_filename = "global-sales-tax-summary-#{year}-#{month}-#{SecureRandom.hex(4)}.csv"
      s3_report_key = "sales-tax/global-summary/#{s3_filename}"
      s3_object = Aws::S3::Resource.new.bucket(REPORTING_S3_BUCKET).object(s3_report_key)
      s3_object.upload_file(temp_file)
      s3_signed_url = s3_object.presigned_url(:get, expires_in: 1.week.to_i).to_s

      AccountingMailer.global_sales_tax_summary_report(month, year, s3_signed_url).deliver_now
      SlackMessageWorker.perform_async("payments", "Global Sales Tax Summary Report", "Global sales tax summary report for #{year}-#{month} is ready - #{s3_signed_url}", "green")
    ensure
      temp_file.close
    end
  end

  private
    def resolve_country_name(purchase)
      raw_name = purchase.country.presence || purchase.ip_country.presence
      return "Unknown" if raw_name.blank?

      country = Compliance::Countries.find_by_name(raw_name)
      country&.common_name || raw_name
    end

    def resolve_state(purchase, country_name)
      case country_name
      when "United States"
        resolve_us_state(purchase)
      when "Canada"
        resolve_canada_province(purchase)
      when "India"
        resolve_india_state(purchase)
      else
        ""
      end
    end

    def resolve_us_state(purchase)
      if purchase.zip_code.present?
        state_code = UsZipCodes.identify_state_code(purchase.zip_code)
        return state_code if state_code.present?
      end

      GeoIp.lookup(purchase.ip_address)&.region_name || ""
    end

    def valid_canada_provinces
      @valid_canada_provinces ||= Compliance::Countries.subdivisions_for_select(Compliance::Countries::CAN.alpha2).map(&:first)
    end

    def resolve_canada_province(purchase)
      if purchase.state.present? && purchase.state.in?(valid_canada_provinces)
        purchase.state
      elsif purchase.ip_state.present? && purchase.ip_state.in?(valid_canada_provinces)
        purchase.ip_state
      else
        ""
      end
    end

    def resolve_india_state(purchase)
      raw_state = (purchase.ip_state || "").strip.upcase
      if !raw_state.match?(/^\d+$/) && CreateIndiaSalesReportJob::VALID_INDIAN_STATES.include?(raw_state)
        raw_state
      else
        ""
      end
    end
end
