# frozen_string_literal: true

class GenerateSalesReportJob
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :default, lock: :until_executed, on_conflict: :replace

  def perform(country_code, start_date, end_date, send_notification = true, s3_prefix = nil)
    country = ISO3166::Country[country_code].tap { |value| raise ArgumentError, "Invalid country code" unless value }

    start_time_of_quarter = Date.parse(start_date.to_s).beginning_of_day
    end_time_of_quarter = Date.parse(end_date.to_s).end_of_day

    begin
      temp_file = Tempfile.new
      temp_file.write(row_headers(country_code).to_csv)

      timeout_seconds = ($redis.get(RedisKey.generate_sales_report_job_max_execution_time_seconds) || 1.hour).to_i
      WithMaxExecutionTime.timeout_queries(seconds: timeout_seconds) do
        Purchase.successful
          .not_fully_refunded
          .not_chargedback_or_chargedback_reversed
          .where.not(stripe_transaction_id: nil)
          .where("purchases.created_at BETWEEN ? AND ?",
                 start_time_of_quarter,
                 end_time_of_quarter)
          .where("(country = ?) OR ((country IS NULL OR country = ?) AND ip_country = ?)", country.common_name, country.common_name, country.common_name)
          .find_each do |purchase|
          row = [purchase.created_at, purchase.external_id,
                 purchase.seller.external_id, purchase.seller.form_email&.gsub(/.{0,4}@/, '####@'),
                 purchase.seller.user_compliance_infos.last&.legal_entity_country,
                 purchase.email&.gsub(/.{0,4}@/, '####@'), purchase.card_visual&.gsub(/.{0,4}@/, '####@'),
                 purchase.price_cents_net_of_refunds, purchase.fee_cents_net_of_refunds, purchase.gumroad_tax_cents_net_of_refunds,
                 purchase.shipping_cents, purchase.total_cents_net_of_refunds]

          if %w(AU SG).include?(country_code)
            row += [purchase.link.is_physical? ? "DTC" : "BS", purchase.zip_tax_rate_id, purchase.purchase_sales_tax_info.business_vat_id]
          end

          temp_file.write(row.to_csv)
          temp_file.flush
        end
      end

      temp_file.rewind

      s3_filename = "#{country.common_name.downcase.tr(' ', '-')}-sales-report-#{start_time_of_quarter.to_date}-to-#{end_time_of_quarter.to_date}-#{SecureRandom.hex(4)}.csv"
      base_path = "sales-tax/#{country.alpha2.downcase}-sales-quarterly/#{s3_filename}"
      s3_report_key = s3_prefix.present? ? "#{s3_prefix.chomp('/')}/#{base_path}" : base_path
      s3_object = Aws::S3::Resource.new.bucket(REPORTING_S3_BUCKET).object(s3_report_key)
      s3_object.upload_file(temp_file)
      s3_signed_url = s3_object.presigned_url(:get, expires_in: 1.week.to_i).to_s

      if send_notification
        message = "#{country.common_name} sales report (#{start_time_of_quarter.to_date} to #{end_time_of_quarter.to_date}) is ready - #{s3_signed_url}"
        SlackMessageWorker.perform_async("payments", slack_sender(country_code), message, "green")
        update_job_status_to_completed(country_code, start_time_of_quarter, end_time_of_quarter, s3_signed_url)
      end
    ensure
      temp_file.close
    end
  end

  private
    def row_headers(country_code)
      headers = ["Sale time", "Sale ID",
                 "Seller ID", "Seller Email",
                 "Seller Country",
                 "Buyer Email", "Buyer Card",
                 "Price", "Gumroad Fee", "GST",
                 "Shipping", "Total"]

      if country_code == "AU"
        headers += ["Direct-To-Customer / Buy-Sell", "Zip Tax Rate ID", "Customer ABN Number"]
      elsif country_code == "SG"
        headers += ["Direct-To-Customer / Buy-Sell", "Zip Tax Rate ID", "Customer GST Number"]
      end

      headers
    end

    def slack_sender(country_code)
      if %w(AU SG).include?(country_code)
        "GST Reporting"
      else
        "VAT Reporting"
      end
    end

    def update_job_status_to_completed(country_code, start_time, end_time, download_url)
      job_data = $redis.lrange(RedisKey.sales_report_jobs, 0, 19)
      job_data.each_with_index do |data, index|
        job = JSON.parse(data)
        if job["country_code"] == country_code &&
           job["start_date"] == start_time.to_date.to_s &&
           job["end_date"] == end_time.to_date.to_s &&
           job["status"] == "processing"
          job["status"] = "completed"
          job["download_url"] = download_url
          $redis.lset(RedisKey.sales_report_jobs, index, job.to_json)
          break
        end
      end
    rescue JSON::ParserError
    end
end
