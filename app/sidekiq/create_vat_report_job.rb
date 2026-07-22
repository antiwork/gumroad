# frozen_string_literal: true

class CreateVatReportJob
  include Sidekiq::Job
  include FinanceReportFailureAlert
  sidekiq_options retry: 5, queue: :default, lock: :until_executed, on_conflict: :replace

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

          # Sales leg. not_chargedback_for_tax_reporting keeps: purchases with no chargeback;
          # reversed (won) chargebacks, which belong in the purchase's own period — this
          # replaces the report's previous exclude-then-add-back pair for won chargebacks with
          # a single query, producing the same totals; and event-dated chargebacks (see
          # Purchase::Reportable::CHARGEBACK_REPORTING_CUTOVER), whose sale stays here while
          # the clawback is reported by the chargeback leg below. Chargebacks lost before the
          # chargeback reporting cutover keep the legacy exclusion so historical quarters
          # regenerate as filed.
          vat_purchases_on_date = zip_tax_rate.purchases
                                                .where("purchase_state != 'failed'")
                                                .where("stripe_transaction_id IS NOT NULL")
                                                .not_chargedback_for_tax_reporting
                                                .where(created_at: date.beginning_of_day..date.end_of_day)

          # Refunds are subtracted in the period the refund happened, not the period of the
          # original purchase. A refund is an event of its own period (matching how OSS/MOSS
          # corrections are reported in the current return), and a purchase from a past quarter
          # refunded this quarter must still reduce this quarter's VAT due. The purchase-side
          # filters mirror the two queries above so we only ever subtract VAT that was (or would
          # have been) reported in the first place: settled purchases whose sale is (or will be)
          # in the report — including event-dated chargebacks: their pre-chargeback refunds
          # also shrink what the chargeback leg claws back, and a refund issued after a dispute
          # win is relieved here alone (the already-filed chargeback legs never change). A
          # purchase dropped by a legacy chargeback never contributes VAT, so its refunds must
          # not be subtracted.
          # Only effective refunds count: a refund that terminally failed after acceptance and
          # had its balance debits reversed never actually returned money to the buyer, so it
          # must not reduce the VAT due (see Refund.effective for the full semantics).
          vat_refunds_on_date = zip_tax_rate.purchases
                                              .where("purchase_state != 'failed'")
                                              .where("stripe_transaction_id IS NOT NULL")
                                              .not_chargedback_for_tax_reporting
                                              .joins(:effective_refunds)
                                              .where(refunds: { created_at: date.beginning_of_day..date.end_of_day })

          # Chargeback (debit) leg: disputes formalized on this day claw their money back in
          # THIS period, regardless of when the purchase happened — purchases.chargeback_date
          # has always held the processor's dispute-formalized event timestamp, so no backfill
          # is needed (see Purchase::Reportable::CHARGEBACK_REPORTING_CUTOVER for the cutover
          # contract; pre-cutover chargebacks keep the legacy exclusion above). Amounts are net
          # of the refunds that existed before the chargeback — money already returned by a
          # refund is not clawed back again and was already relieved by the refund's own
          # reporting path. Later refunds (possible again after a dispute win) never rewrite
          # these legs; they report through the refund leg of their own period.
          vat_chargebacks_on_date = zip_tax_rate.purchases
                                                  .where("purchase_state != 'failed'")
                                                  .where("stripe_transaction_id IS NOT NULL")
                                                  .chargebacks_for_tax_period_reporting(date.beginning_of_day, date.end_of_day)

          # Chargeback-reversal (won) leg: disputes won on this day add their money back in
          # THIS period, dated by the Dispute row's won_at. Only real dispute rows supply
          # reversal dates — never synthesized (reliable 2016+; see app/models/dispute.rb).
          vat_chargeback_reversals_on_date = zip_tax_rate.purchases
                                                           .where("purchase_state != 'failed'")
                                                           .where("stripe_transaction_id IS NOT NULL")
                                                           .chargeback_reversals_for_tax_period_reporting(date.beginning_of_day, date.end_of_day)

          total_purchase_excluding_vat_amount_cents = vat_purchases_on_date.sum(:price_cents)
          total_purchase_vat_cents = vat_purchases_on_date.sum(:gumroad_tax_cents)

          total_refund_excluding_vat_amount_cents = nil
          total_refund_vat_cents = nil
          total_chargeback_excluding_vat_amount_cents = 0
          total_chargeback_vat_cents = 0
          timeout_seconds = ($redis.get(RedisKey.create_vat_report_job_max_execution_time_seconds) || 1.hour).to_i
          WithMaxExecutionTime.timeout_queries(seconds: timeout_seconds) do
            total_refund_excluding_vat_amount_cents = vat_refunds_on_date.sum("refunds.amount_cents")
            total_refund_vat_cents = vat_refunds_on_date.sum("refunds.gumroad_tax_cents")

            # Per-row because the leg amounts are net of each purchase's refunds (a correlated
            # per-purchase sum); daily chargeback volume is tiny, so this stays cheap.
            vat_chargebacks_on_date.find_each do |purchase|
              total_chargeback_excluding_vat_amount_cents += purchase.price_cents_for_chargeback_reporting
              total_chargeback_vat_cents += purchase.gumroad_tax_cents_for_chargeback_reporting
            end

            vat_chargeback_reversals_on_date.find_each do |purchase|
              total_chargeback_excluding_vat_amount_cents -= purchase.price_cents_for_chargeback_reporting
              total_chargeback_vat_cents -= purchase.gumroad_tax_cents_for_chargeback_reporting
            end
          end

          net_excluding_vat_cents = total_purchase_excluding_vat_amount_cents - total_refund_excluding_vat_amount_cents - total_chargeback_excluding_vat_amount_cents
          net_vat_cents = total_purchase_vat_cents - total_refund_vat_cents - total_chargeback_vat_cents

          total_excluding_vat_cents += net_excluding_vat_cents
          total_excluding_vat_cents_estimated += net_vat_cents / zip_tax_rate.combined_rate
          total_vat_cents += net_vat_cents

          total_excluding_vat_cents_in_gbp += net_excluding_vat_cents / conversion_rate
          total_excluding_vat_cents_estimated_in_gbp += (net_vat_cents / zip_tax_rate.combined_rate) / conversion_rate
          total_vat_cents_in_gbp += net_vat_cents / conversion_rate
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
      InternalNotificationWorker.perform_async("payments", "VAT Reporting", "Q#{quarter} #{year} VAT report is ready - #{s3_signed_url}", "green")
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
