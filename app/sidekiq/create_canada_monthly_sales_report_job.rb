# frozen_string_literal: true

class CreateCanadaMonthlySalesReportJob
  include Sidekiq::Job
  include FinanceReportFailureAlert
  include LongRunningJobTracking
  sidekiq_options retry: 5, queue: :default, lock: :until_executed, on_conflict: :replace

  # Rows are written one batch at a time: this sizes the primary-key batches each leg loads, the
  # single flush that follows each one, and the round of association loads inside it.
  ROW_BATCH_SIZE = 1_000
  # Everything a row builder reads beyond the purchase's own columns: the product type and TaxJar
  # rates, plus the refunds/disputes the net-of-refunds and chargeback amounts are computed from.
  PURCHASE_PRELOADS = [:link, :purchase_taxjar_info, :disputes, :refunds, { charge: :dispute }].freeze

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

        # Sales leg. not_chargedback_for_tax_reporting keeps, on top of the reversed (won)
        # chargebacks the old scope kept, event-dated chargebacks (see
        # Purchase::Reportable::CHARGEBACK_REPORTING_CUTOVER): their sale stays reported in
        # the purchase's own month while the clawback is reported by the chargeback leg
        # below. Chargebacks lost before the chargeback reporting cutover keep the legacy
        # drop so historical months regenerate as filed.
        each_purchase_batch(Purchase.successful
          .not_fully_refunded_for_tax_reporting
          .not_chargedback_for_tax_reporting
          .where.not(stripe_transaction_id: nil)
          .where("purchases.created_at BETWEEN ? AND ?", starts_at, ends_at)
          .where("(country = 'Canada') OR (country IS NULL AND ip_country = 'Canada')")
          .where("ip_country = 'Canada' OR card_country = 'CA'")
          .where(state: Compliance::Countries.subdivisions_for_select(Compliance::Countries::CAN.alpha2).map(&:first))
          .where(charge_processor_id: [nil, *ChargeProcessor.charge_processor_ids])) do |batch|
          batch.each do |purchase|
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
          end
          temp_file.flush
        end

        # Refund leg: refunds issued during the reported month appear as their own negative
        # rows, dated by the refund's date, regardless of when the original purchase happened.
        # The purchase-side filters mirror the sales leg above (minus its date window) so a
        # refund is only reported when its purchase's sale was — or would have been — reported;
        # refunds of event-dated chargebacks ARE reported, since their sale row stays and the
        # chargeback leg claws back only what the refund didn't.
        each_refund_batch(Refund.for_tax_period_reporting(starts_at, ends_at)
          .joins(:purchase)
          .merge(
            Purchase.successful
              .not_chargedback_for_tax_reporting
              .where.not(purchases: { stripe_transaction_id: nil })
              .where("(purchases.country = 'Canada') OR (purchases.country IS NULL AND purchases.ip_country = 'Canada')")
              .where("purchases.ip_country = 'Canada' OR purchases.card_country = 'CA'")
              .where(purchases: { state: Compliance::Countries.subdivisions_for_select(Compliance::Countries::CAN.alpha2).map(&:first) })
              .where(purchases: { charge_processor_id: [nil, *ChargeProcessor.charge_processor_ids] })
          )) do |batch|
          batch.each do |refund|
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
          end
          temp_file.flush
        end

        # Chargeback leg: disputes formalized during the reported month appear as their own
        # negative rows, dated by the dispute event date (purchases.chargeback_date has
        # always held the processor's dispute-formalized timestamp, so no backfill is
        # needed). Amounts are net of the purchase's refunds — money already returned by a
        # refund was relieved by the refund's own reporting path and is not clawed back again.
        each_purchase_batch(canada_purchase_filters(Purchase.chargebacks_for_tax_period_reporting(starts_at, ends_at))) do |batch|
          batch.each do |purchase|
            row = chargeback_row(purchase, purchase.chargeback_date, -1)
            next unless row

            temp_file.write(row.to_csv)
          end
          temp_file.flush
        end

        # Chargeback-reversal leg: disputes won during the reported month add their money
        # back as positive rows dated by the Dispute row's won_at (real dispute rows only —
        # reversal dates are never synthesized).
        each_purchase_batch(canada_purchase_filters(Purchase.chargeback_reversals_for_tax_period_reporting(starts_at, ends_at))) do |batch|
          batch.each do |purchase|
            won_at = purchase.chargeback_reversal_reporting_date
            next unless won_at&.between?(starts_at, ends_at)

            row = chargeback_row(purchase, won_at, 1)
            next unless row

            temp_file.write(row.to_csv)
          end
          temp_file.flush
        end
      end

      temp_file.rewind

      s3_filename = "canada-sales-report-#{year}-#{month}-#{SecureRandom.hex(4)}.csv"
      s3_report_key = "sales-tax/ca-sales-monthly/#{s3_filename}"
      s3_object = Aws::S3::Resource.new.bucket(REPORTING_S3_BUCKET).object(s3_report_key)
      s3_object.upload_file(temp_file)
      s3_signed_url = s3_object.presigned_url(:get, expires_in: 1.week.to_i).to_s

      InternalNotificationWorker.perform_async(
        "payments",
        "Canada Sales Reporting",
        "Canada #{year}-#{month} sales report is ready - #{s3_signed_url}",
        "green",
        { "s3_attachments" => [{ "bucket" => REPORTING_S3_BUCKET, "key" => s3_report_key, "filename" => s3_filename }] }
      )
    ensure
      temp_file.close
    end
  end

  private
    # Walks a leg in primary-key batches, yielding one preloaded batch at a time. Each batch is
    # loaded back through the leg's own scope so its filters still hold at read time; the id order
    # is applied after the walk because walking a filtered scope in id order scans the primary key.
    def each_purchase_batch(scope, &block)
      each_batch(scope) { |slice| block.call(scope.where(id: slice).order(:id).preload(*PURCHASE_PRELOADS)) }
    end

    def each_refund_batch(scope, &block)
      each_batch(scope) { |slice| block.call(scope.where(id: slice).order(:id).preload(purchase: PURCHASE_PRELOADS)) }
    end

    def each_batch(scope, &block)
      scope.pluck(:id).sort.each_slice(ROW_BATCH_SIZE, &block)
    end

    # The Canada-report purchase filters shared by the chargeback legs — the sales leg's
    # selection minus its purchase-date window: a chargeback leg belongs to the month of the
    # dispute event (or the win), not the purchase month, but it must only appear when the
    # purchase's sale was (or would have been) reported by this job.
    def canada_purchase_filters(scope)
      scope
        .successful
        .where.not(stripe_transaction_id: nil)
        .where("(country = 'Canada') OR (country IS NULL AND ip_country = 'Canada')")
        .where("ip_country = 'Canada' OR card_country = 'CA'")
        .where(state: Compliance::Countries.subdivisions_for_select(Compliance::Countries::CAN.alpha2).map(&:first))
        .where(charge_processor_id: [nil, *ChargeProcessor.charge_processor_ids])
    end

    # A chargeback (sign = -1) or chargeback-reversal (sign = +1) row: same columns as a sale
    # row, dated by the dispute event (or win) and carrying the purchase's amounts net of its
    # refunds (see Purchase::Reportable#price_cents_for_chargeback_reporting), signed.
    def chargeback_row(purchase, event_date, sign)
      gumroad_tax_cents = sign * purchase.gumroad_tax_cents_for_chargeback_reporting
      price_cents = sign * purchase.price_cents_for_chargeback_reporting
      fee_cents = sign * purchase.fee_cents_for_chargeback_reporting
      total_cents = sign * purchase.total_cents_for_chargeback_reporting

      # A purchase fully refunded before its chargeback claws back nothing — every
      # net-of-refunds amount is zero. Skip the spurious all-zero row (the fees report guards
      # its fee leg the same way).
      return if [gumroad_tax_cents, price_cents, fee_cents, total_cents].all?(&:zero?)

      taxjar_info = purchase.purchase_taxjar_info

      [
        purchase.external_id,
        event_date.strftime("%m/%d/%Y"),
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
        Money.new(0).format(no_cents_if_whole: false, symbol: false),
        Money.new(total_cents).format(no_cents_if_whole: false, symbol: false),
        purchase.receipt_url
      ]
    end

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
