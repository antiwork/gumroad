# frozen_string_literal: true

class CreateVatReportJob
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :default, lock: :until_executed, on_conflict: :replace

  DEFAULT_VAT_RATE_TYPE = "Standard"
  REDUCED_VAT_RATE_TYPE = "Reduced"

  def perform(quarter, year)
    raise ArgumentError, "Invalid quarter" unless quarter.in?(1..4)
    raise ArgumentError, "Invalid year" unless year.in?(2014..3200)

    s3_report_key = "sales-tax/vat-quarterly/vat-report-Q#{quarter}-#{year}-#{SecureRandom.hex(4)}.csv"

    row_headers = ["Member State of Consumption", "VAT rate type", "VAT rate in Member State",
                   "Total value of supplies excluding VAT (USD)",
                   "Total value of supplies excluding VAT (Estimated, USD)",
                   "VAT amount due (USD)",
                   "Total value of supplies excluding VAT (GBP)",
                   "Total value of supplies excluding VAT (Estimated, GBP)",
                   "VAT amount due (GBP)"]

    begin
      temp_file = Tempfile.new
      temp_file.write(row_headers.to_csv)

      ZipTaxRate.where(state: nil, user_id: nil).each do |zip_tax_rate|
        next unless zip_tax_rate.combined_rate > 0

        total_excluding_vat_cents = 0
        total_vat_cents = 0
        total_excluding_vat_cents_estimated = 0
        total_excluding_vat_cents_in_gbp = 0
        total_vat_cents_in_gbp = 0
        total_excluding_vat_cents_estimated_in_gbp = 0

        start_date_of_quarter = Date.new(year, (1 + 3 * (quarter - 1)).to_i).beginning_of_month
        end_date_of_quarter = Date.new(year, (3 + 3 * (quarter - 1)).to_i).end_of_month

        (start_date_of_quarter..end_date_of_quarter).each do |date|
          conversion_rate = gbp_to_usd_rate_for_date(date)

          vat_purchases_on_date = zip_tax_rate.purchases
                                                .where("purchase_state != 'failed'")
                                                .where("stripe_transaction_id IS NOT NULL")
                                                .not_chargedback
                                                .where(created_at: date.beginning_of_day..date.end_of_day)

          vat_chargeback_won_purchases_on_date = zip_tax_rate.purchases
                                                               .where("purchase_state != 'failed'")
                                                               .chargedback
                                                               .where("flags & :bit = :bit", bit: Purchase.flag_mapping["flags"][:chargeback_reversed])
                                                               .where(created_at: date.beginning_of_day..date.end_of_day)

          vat_refunds_on_date = zip_tax_rate.purchases
                                              .where("purchase_state != 'failed'")
                                              .joins(:refunds)
                                              .where(created_at: date.beginning_of_day..date.end_of_day)

          total_purchase_excluding_vat_amount_cents = vat_purchases_on_date.sum(:price_cents)
          total_purchase_vat_cents = vat_purchases_on_date.sum(:gumroad_tax_cents)

          total_purchase_excluding_vat_amount_cents += vat_chargeback_won_purchases_on_date.sum(:price_cents)
          total_purchase_vat_cents += vat_chargeback_won_purchases_on_date.sum(:gumroad_tax_cents)

          total_refund_excluding_vat_amount_cents = nil
          total_refund_vat_cents = nil
          timeout_seconds = ($redis.get(RedisKey.create_vat_report_job_max_execution_time_seconds) || 1.hour).to_i
          WithMaxExecutionTime.timeout_queries(seconds: timeout_seconds) do
            total_refund_excluding_vat_amount_cents = vat_refunds_on_date.sum("refunds.amount_cents")
            total_refund_vat_cents = vat_refunds_on_date.sum("refunds.gumroad_tax_cents")
          end

          total_excluding_vat_cents += total_purchase_excluding_vat_amount_cents - total_refund_excluding_vat_amount_cents
          total_excluding_vat_cents_estimated += (total_purchase_vat_cents - total_refund_vat_cents) / zip_tax_rate.combined_rate
          total_vat_cents += total_purchase_vat_cents - total_refund_vat_cents

          total_excluding_vat_cents_in_gbp += (total_purchase_excluding_vat_amount_cents - total_refund_excluding_vat_amount_cents) / conversion_rate
          total_excluding_vat_cents_estimated_in_gbp += ((total_purchase_vat_cents - total_refund_vat_cents) / zip_tax_rate.combined_rate) / conversion_rate
          total_vat_cents_in_gbp += (total_purchase_vat_cents - total_refund_vat_cents) / conversion_rate
        end

        temp_file.write([ISO3166::Country[zip_tax_rate.country].common_name,
                         zip_tax_rate.is_epublication_rate ? REDUCED_VAT_RATE_TYPE : DEFAULT_VAT_RATE_TYPE,
                         zip_tax_rate.combined_rate * 100,
                         Money.new(total_excluding_vat_cents, :usd).format(no_cents_if_whole: false, symbol: false),
                         Money.new(total_excluding_vat_cents_estimated, :usd).format(no_cents_if_whole: false, symbol: false),
                         Money.new(total_vat_cents, :usd).format(no_cents_if_whole: false, symbol: false),
                         Money.new(total_excluding_vat_cents_in_gbp, :usd).format(no_cents_if_whole: false, symbol: false),
                         Money.new(total_excluding_vat_cents_estimated_in_gbp, :usd).format(no_cents_if_whole: false, symbol: false),
                         Money.new(total_vat_cents_in_gbp, :usd).format(no_cents_if_whole: false, symbol: false)].to_csv)
        temp_file.flush
      end
      temp_file.rewind
      s3_object = Aws::S3::Resource.new.bucket(REPORTING_S3_BUCKET).object(s3_report_key)
      s3_object.upload_file(temp_file)
      s3_signed_url = s3_object.presigned_url(:get, expires_in: 1.week.to_i).to_s

      AccountingMailer.vat_report(quarter, year, s3_signed_url).deliver_now
      SlackMessageWorker.perform_async("payments", "VAT Reporting", "Q#{quarter} #{year} VAT report is ready - #{s3_signed_url}", "green")
    ensure
      temp_file.close
    end
  end

  private
    def gbp_to_usd_rate_for_date(date)
      formatted_date = date.strftime("%Y-%m-%d")
      api_url =
        "#{OPEN_EXCHANGE_RATES_API_BASE_URL}/historical/#{formatted_date}.json?app_id=#{OPEN_EXCHANGE_RATE_KEY}&base=GBP"

      JSON.parse(URI.open(api_url).read)["rates"]["USD"]
    end
end
