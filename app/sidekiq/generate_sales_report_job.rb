# frozen_string_literal: true

class GenerateSalesReportJob
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :default, lock: :until_executed, on_conflict: :replace

  ALL_SALES = "all_sales"
  DISCOVER_SALES = "discover_sales"
  SALES_TYPES = [ALL_SALES, DISCOVER_SALES]

  def perform(country_code, start_date, end_date, sales_type, send_slack_notification = true, s3_prefix = nil)
    country = ISO3166::Country[country_code].tap { |value| raise ArgumentError, "Invalid country code" unless value }
    raise ArgumentError, "Invalid sales type" unless SALES_TYPES.include?(sales_type)

    start_time = Date.parse(start_date.to_s).beginning_of_day
    end_time = Date.parse(end_date.to_s).end_of_day

    begin
      temp_file = Tempfile.new
      temp_file.write(row_headers(country_code).to_csv)

      timeout_seconds = ($redis.get(RedisKey.generate_sales_report_job_max_execution_time_seconds) || 1.hour).to_i
      WithMaxExecutionTime.timeout_queries(seconds: timeout_seconds) do
        sales = Purchase.successful
                        .not_fully_refunded
                        .not_chargedback_or_chargedback_reversed
                        .where.not(stripe_transaction_id: nil)
                        .where("purchases.created_at BETWEEN ? AND ?",
                               start_time,
                               end_time)
                        .where("(country = ?) OR ((country IS NULL OR country = ?) AND ip_country = ?)", country.common_name, country.common_name, country.common_name)

        sales = sales.where("purchases.flags & ? > 0", Purchase.flag_mapping["flags"][:was_product_recommended]) if sales_type == DISCOVER_SALES

        sales.find_each do |purchase|
          row = [purchase.created_at, purchase.external_id,
                 purchase.seller.external_id, purchase.seller.form_email&.gsub(/.{0,4}@/, '####@'),
                 purchase.seller.user_compliance_infos.last&.legal_entity_country,
                 purchase.email&.gsub(/.{0,4}@/, '####@'), purchase.card_visual&.gsub(/.{0,4}@/, '####@'),
                 purchase.price_cents_net_of_refunds, purchase.fee_cents_net_of_refunds, purchase.gumroad_tax_cents_net_of_refunds,
                 purchase.shipping_cents, purchase.total_cents_net_of_refunds]

          if %w(AU SG).include?(country_code)
            row += [purchase.link.is_physical? ? "DTC" : "BS", purchase.zip_tax_rate_id, purchase.purchase_sales_tax_info.business_vat_id]
          end

          # Do not include free recommendations like library and more-like-this in the discover sales report
          # because we don't charge our discover/marketplace fee in those cases.
          next if sales_type == DISCOVER_SALES && RecommendationType.is_free_recommendation_type?(purchase.recommended_by)

          temp_file.write(row.to_csv)
          temp_file.flush
        end
      end

      temp_file.rewind

      s3_filename = "#{country.common_name.downcase.tr(' ', '-')}-#{sales_type.tr("_", "-")}-report-#{start_time.to_date}-to-#{end_time.to_date}-#{SecureRandom.hex(4)}.csv"
      s3_path = s3_prefix.present? ? "#{s3_prefix.chomp('/')}/sales-tax/#{country.alpha2.downcase}-sales-quarterly" : "sales-tax/#{country.alpha2.downcase}-sales-quarterly"
      s3_signed_url = ExpiringS3FileService.new(
        file: temp_file,
        filename: s3_filename,
        path: s3_path,
        expiry: 1.week,
        bucket: REPORTING_S3_BUCKET
      ).perform

      update_job_status_to_completed(country_code, start_time, end_time, sales_type, s3_signed_url)

      if send_slack_notification
        message = "#{country.common_name} sales report (#{start_time.to_date} to #{end_time.to_date}) is ready - #{s3_signed_url}"
        SlackMessageWorker.perform_async("payments", slack_sender(country_code), message, "green")
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

    def update_job_status_to_completed(country_code, start_time, end_time, sales_type, download_url)
      job_data = $redis.lrange(RedisKey.sales_report_jobs, 0, 19)
      job_data.each_with_index do |data, index|
        job = JSON.parse(data)
        if job["country_code"] == country_code &&
           job["start_date"] == start_time.to_date.to_s &&
           job["end_date"] == end_time.to_date.to_s &&
           job["sales_type"] == sales_type &&
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
