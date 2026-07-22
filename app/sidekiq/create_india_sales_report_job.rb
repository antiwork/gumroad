# frozen_string_literal: true

class CreateIndiaSalesReportJob
  include Sidekiq::Job
  include FinanceReportFailureAlert
  sidekiq_options retry: 5, queue: :default, lock: :until_executed, on_conflict: :replace

  # The scheduler fires with no args; pin the resolved period in the exhaustion alert so a
  # late re-run reports the month the failed run was for (not whatever "last month" is then).
  def self.default_alert_args(reference_time = Time.current)
    previous_month = reference_time.last_month
    [previous_month.month, previous_month.year]
  end

  def perform(month = nil, year = nil)
    if month.nil? || year.nil?
      previous_month = 1.month.ago
      month ||= previous_month.month
      year ||= previous_month.year
    end

    raise ArgumentError, "Invalid month" unless month.in?(1..12)
    raise ArgumentError, "Invalid year" unless year.in?(2014..3200)

    s3_filename = "india-sales-report-#{year}-#{month.to_s.rjust(2, '0')}-#{SecureRandom.hex(4)}.csv"
    s3_report_key = "sales-tax/in-sales-monthly/#{s3_filename}"

    begin
      temp_file = Tempfile.new
      temp_file.write(row_headers.to_csv)

      start_date = Date.new(year, month).beginning_of_month.beginning_of_day
      end_date = Date.new(year, month).end_of_month.end_of_day

      india_tax_rate = ZipTaxRate.where(country: "IN", state: nil, user_id: nil).alive.last.combined_rate
      india_tax_rate_percentage = (india_tax_rate * 100).to_i

      timeout_seconds = ($redis.get("create_india_sales_report_job_max_execution_time_seconds") || 1.hour).to_i
      WithMaxExecutionTime.timeout_queries(seconds: timeout_seconds) do
        # Sales leg: every taxable sale made inside the report month, keyed on the purchase
        # date. Refunded purchases are intentionally NOT skipped here — the gross sale stays
        # in the month it happened, and the refund shows up as its own entry (below) in the
        # month the refund happened. This matches how GST treats credit notes (separate
        # entries dated by the credit note, not retroactive edits to the original invoice)
        # and makes re-generating a past month's report deterministic: a refund issued later
        # can no longer silently remove a sale from an already-filed month.
        #
        # Chargebacks get the same treatment from the chargeback reporting cutover on: an
        # event-dated chargeback keeps its sale row here and is backed out by its own negative
        # entry (below) in the month the dispute was formalized. Only legacy (pre-cutover)
        # chargebacks keep the historical drop, so already-filed months regenerate as filed.
        # See Purchase::Reportable::CHARGEBACK_REPORTING_CUTOVER for the cutover contract.
        india_purchases(start_date, end_date).find_each do |purchase|
          next if purchase.chargedback_not_reversed? && !purchase.chargeback_event_dated_for_tax_reporting?

          temp_file.write(sale_row(purchase, india_tax_rate, india_tax_rate_percentage).to_csv)
          temp_file.flush
        end

        # Refund leg: every refund issued inside the report month, keyed on the refund date
        # (refunds.created_at), regardless of when the original purchase happened. Amounts
        # are negative so summing a column still nets out correctly. The purchase-side
        # filters mirror the sales leg so we only ever back out tax that was (or would have
        # been) reported in the first place; a purchase dropped by a legacy chargeback never
        # contributes to the report, so its refunds must not be backed out either. Refunds of
        # event-dated chargebacks ARE backed out — their sale row stays, and the chargeback
        # entry claws back only what the refund didn't (see chargeback_row).
        india_refunds(start_date, end_date).find_each do |refund|
          purchase = refund.purchase
          next if purchase.chargedback_not_reversed? && !purchase.chargeback_event_dated_for_tax_reporting?

          temp_file.write(refund_row(refund, purchase, india_tax_rate, india_tax_rate_percentage).to_csv)
          temp_file.flush
        end

        # Chargeback leg: every dispute formalized inside the report month, keyed on the
        # dispute event date (purchases.chargeback_date has always held the processor's
        # dispute-formalized timestamp, so no backfill is needed). Negative amounts, net of
        # the purchase's refunds — money already returned by a refund was relieved by the
        # refund leg and is not clawed back again.
        india_chargebacks(start_date, end_date).find_each do |purchase|
          temp_file.write(chargeback_row(purchase, india_tax_rate, india_tax_rate_percentage).to_csv)
          temp_file.flush
        end

        # Chargeback-reversal leg: every dispute won inside the report month, keyed on the
        # Dispute row's won_at (real dispute rows only — reversal dates are never
        # synthesized). Positive amounts mirroring the chargeback entry they cancel.
        india_chargeback_reversals(start_date, end_date).find_each do |purchase|
          won_at = purchase.chargeback_reversal_reporting_date
          next unless won_at&.between?(start_date, end_date)

          temp_file.write(chargeback_reversal_row(purchase, won_at, india_tax_rate, india_tax_rate_percentage).to_csv)
          temp_file.flush
        end
      end

      temp_file.rewind
      s3_object = Aws::S3::Resource.new.bucket(REPORTING_S3_BUCKET).object(s3_report_key)
      s3_object.upload_file(temp_file)
      s3_signed_url = s3_object.presigned_url(:get, expires_in: 1.week.to_i).to_s

      InternalNotificationWorker.perform_async("payments", "India Sales Reporting", "India #{year}-#{month.to_s.rjust(2, '0')} sales report is ready - #{s3_signed_url}", "green")
    ensure
      temp_file.close
    end
  end

  private
    def row_headers
      [
        "ID",
        "Date",
        "Place of Supply (State)",
        "Zip Tax Rate (%) (Rate from Database)",
        "Taxable Value (cents)",
        "Integrated Tax Amount (cents)",
        "Tax Rate (%) (Calculated From Tax Collected)",
        "Expected Tax (cents, rounded)",
        "Expected Tax (cents, floored)",
        "Tax Difference (rounded)",
        "Tax Difference (floored)",
        "Entry Type"
      ]
    end

    # Taxable Indian consumer sales made inside the window, keyed on the purchase date.
    def india_purchases(start_date, end_date)
      india_purchase_filters(Purchase.where(created_at: start_date..end_date))
    end

    # Refunds issued inside the window (keyed on refunds.created_at), restricted to
    # purchases that qualify for the sales leg — same filters as india_purchases, just
    # written against the joined purchases table.
    #
    # Refund.effective drops terminally-failed refunds (an async bank-transfer refund the
    # buyer's bank returned, or a canceled pending refund) whose balance debits were reversed:
    # the money came back to us and the buyer never received it, so it must not back tax out of
    # the report. This is the same "only real refunds count" guard the VAT report applies via
    # joins(:effective_refunds); the old drop-refunded-rows code never saw these because it
    # keyed off stripe_refunded, which a failed refund never sets.
    def india_refunds(start_date, end_date)
      Refund.effective
            .joins(:purchase)
            .joins("LEFT JOIN purchase_sales_tax_infos ON purchases.id = purchase_sales_tax_infos.purchase_id")
            .where(refunds: { created_at: start_date..end_date })
            .where("purchases.purchase_state != 'failed'")
            .where.not(purchases: { stripe_transaction_id: nil })
            .where("(purchases.country = 'India') OR (purchases.country IS NULL AND purchases.ip_country = 'India') OR (purchases.card_country = 'IN')")
            .where("purchases.price_cents > 0")
            .where("purchase_sales_tax_infos.business_vat_id IS NULL OR purchase_sales_tax_infos.business_vat_id = ''")
    end

    # Purchases whose chargeback (debit) entry lands in the window, keyed on the dispute
    # event date. Same purchase-side filters as india_purchases, minus its purchase-date
    # window: the entry belongs to the month of chargeback_date, not the purchase month.
    def india_chargebacks(start_date, end_date)
      india_purchase_filters(Purchase.chargebacks_for_tax_period_reporting(start_date, end_date))
    end

    # Purchases with a dispute won inside the window (real Dispute rows only). The scope
    # over-selects slightly (any matching dispute row); the caller re-checks the resolved
    # won_at per row before writing the entry.
    def india_chargeback_reversals(start_date, end_date)
      india_purchase_filters(Purchase.chargeback_reversals_for_tax_period_reporting(start_date, end_date))
    end

    # The India-report purchase filters shared by every leg, applied to an arbitrary base
    # scope (see india_purchases for the canonical purchase-date-windowed version).
    def india_purchase_filters(scope)
      scope
        .joins("LEFT JOIN purchase_sales_tax_infos ON purchases.id = purchase_sales_tax_infos.purchase_id")
        .where("purchase_state != 'failed'")
        .where.not(stripe_transaction_id: nil)
        .where("(country = 'India') OR (country IS NULL AND ip_country = 'India') OR (card_country = 'IN')")
        .where("price_cents > 0")
        .where("purchase_sales_tax_infos.business_vat_id IS NULL OR purchase_sales_tax_infos.business_vat_id = ''")
    end

    def sale_row(purchase, india_tax_rate, india_tax_rate_percentage)
      build_row(
        id: purchase.external_id,
        date: purchase.created_at,
        purchase:,
        price_cents: purchase.price_cents,
        tax_amount_cents: purchase.gumroad_tax_cents || 0,
        india_tax_rate:,
        india_tax_rate_percentage:,
        entry_type: "sale"
      )
    end

    def refund_row(refund, purchase, india_tax_rate, india_tax_rate_percentage)
      build_row(
        id: purchase.external_id,
        date: refund.created_at,
        purchase:,
        # Negated so the refund backs out (part of) the original sale when columns are
        # summed. amount_cents is the price portion of the refund, so partial refunds
        # back out exactly what was refunded.
        price_cents: -(refund.amount_cents || 0),
        tax_amount_cents: -(refund.gumroad_tax_cents || 0),
        india_tax_rate:,
        india_tax_rate_percentage:,
        entry_type: "refund"
      )
    end

    # Dated by the dispute event (chargeback_date); negated, net of the purchase's refunds,
    # so a sale + its refunds + its chargeback entry sum to zero across the months involved.
    def chargeback_row(purchase, india_tax_rate, india_tax_rate_percentage)
      build_row(
        id: purchase.external_id,
        date: purchase.chargeback_date,
        purchase:,
        price_cents: -purchase.price_cents_for_chargeback_reporting,
        tax_amount_cents: -purchase.gumroad_tax_cents_for_chargeback_reporting,
        india_tax_rate:,
        india_tax_rate_percentage:,
        entry_type: "chargeback"
      )
    end

    # Dated by the dispute's won_at; the exact positive mirror of the chargeback entry.
    def chargeback_reversal_row(purchase, won_at, india_tax_rate, india_tax_rate_percentage)
      build_row(
        id: purchase.external_id,
        date: won_at,
        purchase:,
        price_cents: purchase.price_cents_for_chargeback_reporting,
        tax_amount_cents: purchase.gumroad_tax_cents_for_chargeback_reporting,
        india_tax_rate:,
        india_tax_rate_percentage:,
        entry_type: "chargeback_reversal"
      )
    end

    def build_row(id:, date:, purchase:, price_cents:, tax_amount_cents:, india_tax_rate:, india_tax_rate_percentage:, entry_type:)
      raw_state = (purchase.ip_state || "").strip.upcase
      display_state = Compliance::Countries.valid_indian_state?(raw_state) ? raw_state : ""

      # Round/floor on the magnitude and re-apply the sign, so a refund's expected tax is
      # exactly the negative of what the same amount produced on the sale side (rounding
      # negative floats directly would sometimes differ by a cent).
      sign = price_cents.negative? ? -1 : 1
      expected_tax_rounded = sign * (price_cents.abs * india_tax_rate).round
      expected_tax_floored = sign * (price_cents.abs * india_tax_rate).floor
      diff_rounded = expected_tax_rounded - tax_amount_cents
      diff_floored = expected_tax_floored - tax_amount_cents

      calc_tax_rate = if price_cents != 0 && tax_amount_cents != 0
        (BigDecimal(tax_amount_cents.to_s) / BigDecimal(price_cents.to_s) * 100).round(4).to_f
      else
        0
      end

      [
        id,
        date.strftime("%Y-%m-%d"),
        display_state,
        india_tax_rate_percentage,
        price_cents,
        tax_amount_cents,
        calc_tax_rate,
        expected_tax_rounded,
        expected_tax_floored,
        diff_rounded,
        diff_floored,
        entry_type
      ]
    end
end
