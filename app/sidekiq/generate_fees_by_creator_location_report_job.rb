# frozen_string_literal: true

class GenerateFeesByCreatorLocationReportJob
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :default, lock: :until_executed

  def perform(month, year)
    raise ArgumentError, "Invalid month" unless month.in?(1..12)
    raise ArgumentError, "Invalid year" unless year.in?(2014..3200)

    state_data = {}
    country_data = {}

    timeout_seconds = ($redis.get(RedisKey.generate_fees_by_creator_location_job_max_execution_time_seconds) || 1.hour).to_i
    WithMaxExecutionTime.timeout_queries(seconds: timeout_seconds) do
      Purchase.successful
        .not_fully_refunded
        .not_chargedback_or_chargedback_reversed
        .where.not(stripe_transaction_id: nil)
        .where("purchases.created_at BETWEEN ? AND ?",
               Date.new(year, month).beginning_of_month.beginning_of_day,
               Date.new(year, month).end_of_month.end_of_day).find_each do |purchase|
        GC.start if purchase.id % 10000 == 0

        next if purchase.chargedback_not_reversed_or_refunded?

        fee_cents = purchase.fee_cents_net_of_refunds

        country_name, state_name = determine_country_name_and_state_name(purchase)

        country_data[country_name] ||= 0
        country_data[country_name] += fee_cents

        if country_name == "United States"
          state_data[state_name] ||= 0
          state_data[state_name] += fee_cents
        end
      end
    end

    row_headers = ["Month", "Creator Country", "Creator State", "Gumroad Fees"]

    begin
      temp_file = Tempfile.new
      temp_file.write(row_headers.to_csv)

      state_data.each do |state_name, state_fee_cents_total|
        temp_file.write([Date.new(year, month).strftime("%B %Y"), "United States", state_name, state_fee_cents_total].to_csv)
      end
      country_data.each do |country_name, country_fee_cents_total|
        temp_file.write([Date.new(year, month).strftime("%B %Y"), country_name, "", country_fee_cents_total].to_csv)
      end

      temp_file.flush
      temp_file.rewind

      s3_filename = "fees-by-creator-location-report-#{year}-#{month}-#{SecureRandom.hex(4)}.csv"
      s3_report_key = "sales-tax/fees-by-creator-location-monthly/#{s3_filename}"
      s3_object = Aws::S3::Resource.new.bucket(REPORTING_S3_BUCKET).object(s3_report_key)
      s3_object.upload_file(temp_file)
      s3_signed_url = s3_object.presigned_url(:get, expires_in: 1.week.to_i).to_s

      SlackMessageWorker.perform_async("payments", "Fee Reporting", "#{year}-#{month} fee by creator location report is ready - #{s3_signed_url}", "green")
    ensure
      temp_file.close
    end
  end

  def determine_country_name_and_state_name(purchase)
    user_compliance_info = purchase.seller.user_compliance_infos.where("created_at < ?", purchase.created_at).where.not("country IS NULL AND business_country IS NULL").last rescue nil
    country_name = user_compliance_info&.legal_entity_country.presence
    state_code = user_compliance_info&.legal_entity_state.presence

    unless country_name.present?
      country_name = purchase.seller&.country
      state_code = purchase.seller&.state
    end

    unless country_name.present?
      country_name = GeoIp.lookup(purchase.seller&.account_created_ip)&.country_name
      state_code = GeoIp.lookup(purchase.seller&.account_created_ip)&.region_name
    end

    country_name = Compliance::Countries.find_by_name(country_name)&.common_name || "Uncategorized"
    state_name = Compliance::Countries::USA.subdivisions[state_code]&.name || "Uncategorized"

    [country_name, state_name]
  end
end
