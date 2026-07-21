# frozen_string_literal: true

class GenerateSalesReportJob
  include Sidekiq::Job
  include FinanceReportFailureAlert
  sidekiq_options retry: 5, queue: :default, lock: :until_executed, on_conflict: :replace

  ALL_SALES = "all_sales"
  DISCOVER_SALES = "discover_sales"
  SALES_TYPES = [ALL_SALES, DISCOVER_SALES]

  def perform(country_code, start_date, end_date, sales_type, send_notification = true, s3_prefix = nil)
    country = ISO3166::Country[country_code].tap { |value| raise ArgumentError, "Invalid country code" unless value }
    raise ArgumentError, "Invalid sales type" unless SALES_TYPES.include?(sales_type)

    start_time = Date.parse(start_date.to_s).beginning_of_day
    end_time = Date.parse(end_date.to_s).end_of_day

    begin
      temp_file = Tempfile.new
      temp_file.write(row_headers(country_code).to_csv)

      timeout_seconds = ($redis.get(RedisKey.generate_sales_report_job_max_execution_time_seconds) || 1.hour).to_i
      WithMaxExecutionTime.timeout_queries(seconds: timeout_seconds) do
        country_condition = ["(purchases.country = ?) OR ((purchases.country IS NULL OR purchases.country = ?) AND purchases.ip_country = ?)",
                             country.common_name, country.common_name, country.common_name]

        # Sales leg. not_chargedback_for_tax_reporting keeps, on top of the reversed (won)
        # chargebacks the old scope kept, event-dated chargebacks (see
        # Purchase::Reportable::CHARGEBACK_REPORTING_CUTOVER): their sale stays reported in
        # the purchase's own period while the clawback is reported by the chargeback leg
        # below. Chargebacks lost before the chargeback reporting cutover keep the legacy
        # drop so historical periods regenerate as filed.
        sales = Purchase.successful
                        .not_fully_refunded_for_tax_reporting
                        .not_chargedback_for_tax_reporting
                        .where.not(stripe_transaction_id: nil)
                        .where("purchases.created_at BETWEEN ? AND ?",
                               start_time,
                               end_time)
                        .where(*country_condition)

        sales = sales.where("purchases.flags & ? > 0", Purchase.flag_mapping["flags"][:was_product_recommended]) if sales_type == DISCOVER_SALES

        sales.find_each do |purchase|
          row = [purchase.created_at, purchase.external_id,
                 purchase.seller.external_id, purchase.seller.form_email&.gsub(/.{0,4}@/, '####@'),
                 purchase.seller.user_compliance_infos.last&.legal_entity_country,
                 purchase.email&.gsub(/.{0,4}@/, '####@'), purchase.card_visual&.gsub(/.{0,4}@/, '####@'),
                 purchase.price_cents_for_tax_reporting, purchase.fee_cents_for_tax_reporting, purchase.gumroad_tax_cents_for_tax_reporting,
                 purchase.shipping_cents, purchase.total_cents_for_tax_reporting, purchase.purchase_sales_tax_info&.business_vat_id]

          if %w(AU SG).include?(country_code)
            row += [purchase.link.is_physical? ? "DTC" : "BS", purchase.zip_tax_rate_id]
          end

          # Do not include free recommendations like library and more-like-this in the discover sales report
          # because we don't charge our discover/marketplace fee in those cases.
          next if sales_type == DISCOVER_SALES && RecommendationType.is_free_recommendation_type?(purchase.recommended_by)

          temp_file.write(row.to_csv)
          temp_file.flush
        end

        # Refund leg: refunds issued during the reported period appear as their own negative
        # rows, dated by the refund's date, regardless of when the original purchase happened.
        # The purchase-side filters mirror the sales leg above (minus its date window) so a
        # refund is only reported when its purchase's sale was — or would have been — reported;
        # refunds of event-dated chargebacks ARE reported, since their sale row stays and the
        # chargeback leg claws back only what the refund didn't.
        refunds = Refund.for_tax_period_reporting(start_time, end_time)
                        .joins(:purchase)
                        .merge(
                          Purchase.successful
                            .not_chargedback_for_tax_reporting
                            .where.not(purchases: { stripe_transaction_id: nil })
                            .where(*country_condition)
                        )

        refunds = refunds.where("purchases.flags & ? > 0", Purchase.flag_mapping["flags"][:was_product_recommended]) if sales_type == DISCOVER_SALES

        refunds.find_each do |refund|
          purchase = refund.purchase

          next if sales_type == DISCOVER_SALES && RecommendationType.is_free_recommendation_type?(purchase.recommended_by)

          row = [refund.created_at, purchase.external_id,
                 purchase.seller.external_id, purchase.seller.form_email&.gsub(/.{0,4}@/, '####@'),
                 purchase.seller.user_compliance_infos.last&.legal_entity_country,
                 purchase.email&.gsub(/.{0,4}@/, '####@'), purchase.card_visual&.gsub(/.{0,4}@/, '####@'),
                 -refund.amount_cents.to_i, -refund.fee_cents.to_i, -refund.gumroad_tax_cents.to_i,
                 0, -refund.total_transaction_cents.to_i, purchase.purchase_sales_tax_info&.business_vat_id]

          if %w(AU SG).include?(country_code)
            row += [purchase.link.is_physical? ? "DTC" : "BS", purchase.zip_tax_rate_id]
          end

          temp_file.write(row.to_csv)
          temp_file.flush
        end

        # Chargeback leg: disputes formalized during the reported period appear as their own
        # negative rows, dated by the dispute event date (purchases.chargeback_date has
        # always held the processor's dispute-formalized timestamp, so no backfill is
        # needed). Amounts are net of the purchase's refunds — money already returned by a
        # refund was relieved by the refund's own reporting path and is not clawed back again.
        chargebacks = Purchase.chargebacks_for_tax_period_reporting(start_time, end_time)
                              .successful
                              .where.not(stripe_transaction_id: nil)
                              .where(*country_condition)
        chargebacks = chargebacks.where("purchases.flags & ? > 0", Purchase.flag_mapping["flags"][:was_product_recommended]) if sales_type == DISCOVER_SALES

        chargebacks.find_each do |purchase|
          next if sales_type == DISCOVER_SALES && RecommendationType.is_free_recommendation_type?(purchase.recommended_by)

          row = chargeback_row(purchase, purchase.chargeback_date, -1, country_code)
          next unless row

          temp_file.write(row.to_csv)
          temp_file.flush
        end

        # Chargeback-reversal leg: disputes won during the reported period add their money
        # back as positive rows dated by the Dispute row's won_at (real dispute rows only —
        # reversal dates are never synthesized).
        reversals = Purchase.chargeback_reversals_for_tax_period_reporting(start_time, end_time)
                            .successful
                            .where.not(stripe_transaction_id: nil)
                            .where(*country_condition)
        reversals = reversals.where("purchases.flags & ? > 0", Purchase.flag_mapping["flags"][:was_product_recommended]) if sales_type == DISCOVER_SALES

        reversals.find_each do |purchase|
          next if sales_type == DISCOVER_SALES && RecommendationType.is_free_recommendation_type?(purchase.recommended_by)

          won_at = purchase.chargeback_reversal_reporting_date
          next unless won_at&.between?(start_time, end_time)

          row = chargeback_row(purchase, won_at, 1, country_code)
          next unless row

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

      if send_notification
        message = "#{country.common_name} sales report (#{start_time.to_date} to #{end_time.to_date}) is ready - #{s3_signed_url}"
        InternalNotificationWorker.perform_async("payments", notification_sender(country_code), message, "green")
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
                 "Shipping", "Total", "Customer Tax ID"]

      if %w(AU SG).include?(country_code)
        headers += ["Direct-To-Customer / Buy-Sell", "Zip Tax Rate ID"]
      end

      headers
    end

    def notification_sender(country_code)
      if %w(AU SG).include?(country_code)
        "GST Reporting"
      else
        "VAT Reporting"
      end
    end

    # A chargeback (sign = -1) or chargeback-reversal (sign = +1) row: same columns as a sale
    # row, dated by the dispute event (or win) and carrying the purchase's amounts net of its
    # refunds (see Purchase::Reportable#price_cents_for_chargeback_reporting), signed.
    def chargeback_row(purchase, event_date, sign, country_code)
      price_cents = sign * purchase.price_cents_for_chargeback_reporting
      fee_cents = sign * purchase.fee_cents_for_chargeback_reporting
      gumroad_tax_cents = sign * purchase.gumroad_tax_cents_for_chargeback_reporting
      total_cents = sign * purchase.total_cents_for_chargeback_reporting

      # A purchase fully refunded before its chargeback claws back nothing — every
      # net-of-refunds amount is zero. Skip the spurious all-zero row.
      return if [price_cents, fee_cents, gumroad_tax_cents, total_cents].all?(&:zero?)

      row = [event_date, purchase.external_id,
             purchase.seller.external_id, purchase.seller.form_email&.gsub(/.{0,4}@/, '####@'),
             purchase.seller.user_compliance_infos.last&.legal_entity_country,
             purchase.email&.gsub(/.{0,4}@/, '####@'), purchase.card_visual&.gsub(/.{0,4}@/, '####@'),
             price_cents, fee_cents, gumroad_tax_cents,
             0, total_cents,
             purchase.purchase_sales_tax_info&.business_vat_id]

      if %w(AU SG).include?(country_code)
        row += [purchase.link.is_physical? ? "DTC" : "BS", purchase.zip_tax_rate_id]
      end

      row
    end

    def update_job_status_to_completed(country_code, start_time, end_time, sales_type, download_url)
      job_data = $redis.lrange(RedisKey.sales_report_jobs, 0, 19)
      job_data.each_with_index do |data, index|
        job = JSON.parse(data)
        if job["country_code"] == country_code &&
           job["start_date"] == start_time.to_date.to_s &&
           job["end_date"] == end_time.to_date.to_s &&
           job["sales_type"] == sales_type &&
           # "failed" is accepted alongside "processing" because the admin page
           # marks a history entry "failed" when its job lands in the Sidekiq
           # Dead set. If an operator then retries that job from the Sidekiq UI
           # and it succeeds, this is the only writer that can flip the entry to
           # "completed" — matching only "processing" would leave a successful
           # report showing as failed forever.
           ["processing", "failed"].include?(job["status"])
          job["status"] = "completed"
          job["download_url"] = download_url
          $redis.lset(RedisKey.sales_report_jobs, index, job.to_json)
          break
        end
      end
    rescue JSON::ParserError
    end
end
