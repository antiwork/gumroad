# frozen_string_literal: true

class GenerateFeesByCreatorLocationReportJob
  include Sidekiq::Job
  include FinanceReportFailureAlert
  sidekiq_options retry: 5, queue: :default, lock: :until_executed

  def perform(month, year)
    raise ArgumentError, "Invalid month" unless month.in?(1..12)
    raise ArgumentError, "Invalid year" unless year.in?(2014..3200)

    state_data = {}
    country_data = {}

    timeout_seconds = ($redis.get(RedisKey.generate_fees_by_creator_location_job_max_execution_time_seconds) || 1.hour).to_i
    WithMaxExecutionTime.timeout_queries(seconds: timeout_seconds) do
      starts_at = Date.new(year, month).beginning_of_month.beginning_of_day
      ends_at = Date.new(year, month).end_of_month.end_of_day

      # Sales leg. not_chargedback_for_tax_reporting keeps, on top of the reversed (won)
      # chargebacks the old scope kept, event-dated chargebacks (see
      # Purchase::Reportable::CHARGEBACK_REPORTING_CUTOVER): their fee stays counted in the
      # purchase's own month while the clawback is subtracted by the chargeback leg below.
      # Chargebacks lost before the chargeback reporting cutover keep the legacy drop so
      # historical months regenerate as filed.
      Purchase.successful
        .not_fully_refunded_for_tax_reporting
        .not_chargedback_for_tax_reporting
        .where.not(stripe_transaction_id: nil)
        .where("purchases.created_at BETWEEN ? AND ?", starts_at, ends_at)
        .includes(:seller).find_each do |purchase|
        GC.start if purchase.id % 10000 == 0

        # There is deliberately NO per-row
        # fully-refunded skip here: the not_fully_refunded_for_tax_reporting scope above is
        # the single gate. Any refunded purchase that reaches this loop either contributes its
        # gross fee (post-cutover) or has a post-cutover refund whose leg below subtracts the
        # refunded fee — re-skipping it here would understate the period pair.
        next if purchase.chargedback_not_reversed? && !purchase.chargeback_event_dated_for_tax_reporting?

        fee_cents = purchase.fee_cents_for_tax_reporting

        country_name, state_name = determine_country_name_and_state_name(purchase)

        country_data[country_name] ||= 0
        country_data[country_name] += fee_cents

        if country_name == "United States"
          state_data[state_name] ||= 0
          state_data[state_name] += fee_cents
        end
      end

      # Refund leg: fees refunded during the reported month are subtracted in this month,
      # dated by the refund's date, regardless of when the original purchase happened. The
      # purchase-side filters mirror the sales leg above (minus its date window); refunds of
      # event-dated chargebacks ARE subtracted, since their fee stays counted and the
      # chargeback leg claws back only what the refund didn't.
      Refund.for_tax_period_reporting(starts_at, ends_at)
        .joins(:purchase)
        .merge(
          Purchase.successful
            .not_chargedback_for_tax_reporting
            .where.not(purchases: { stripe_transaction_id: nil })
        )
        .includes(purchase: :seller)
        .find_each do |refund|
        refunded_fee_cents = refund.fee_cents.to_i
        next if refunded_fee_cents.zero?

        country_name, state_name = determine_country_name_and_state_name(refund.purchase)

        country_data[country_name] ||= 0
        country_data[country_name] -= refunded_fee_cents

        if country_name == "United States"
          state_data[state_name] ||= 0
          state_data[state_name] -= refunded_fee_cents
        end
      end

      # Chargeback leg: fees clawed back by disputes formalized during the reported month are
      # subtracted in this month, dated by the dispute event date (purchases.chargeback_date
      # has always held the processor's dispute-formalized timestamp, so no backfill is
      # needed). Amounts are net of the purchase's refunds — a refunded fee was already
      # subtracted by the refund's own reporting path and is not clawed back again.
      Purchase.chargebacks_for_tax_period_reporting(starts_at, ends_at)
        .successful
        .where.not(stripe_transaction_id: nil)
        .includes(:seller)
        .find_each do |purchase|
        apply_chargeback_fee(purchase, -1, country_data, state_data)
      end

      # Chargeback-reversal leg: fees from disputes won during the reported month are added
      # back in this month, dated by the Dispute row's won_at (real dispute rows only —
      # reversal dates are never synthesized).
      Purchase.chargeback_reversals_for_tax_period_reporting(starts_at, ends_at)
        .successful
        .where.not(stripe_transaction_id: nil)
        .includes(:seller)
        .find_each do |purchase|
        won_at = purchase.chargeback_reversal_reporting_date
        next unless won_at&.between?(starts_at, ends_at)

        apply_chargeback_fee(purchase, 1, country_data, state_data)
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

      InternalNotificationWorker.perform_async("payments", "Fee Reporting", "#{year}-#{month} fee by creator location report is ready - #{s3_signed_url}", "green")
    ensure
      temp_file.close
    end
  end

  def determine_country_name_and_state_name(purchase)
    user_compliance_info = compliance_info_for(purchase)
    country_name = user_compliance_info&.legal_entity_country.presence
    state_code = user_compliance_info&.legal_entity_state.presence

    unless country_name.present?
      country_name = purchase.seller&.country
      state_code = purchase.seller&.state
    end

    unless country_name.present?
      geo_ip_location = GeoIp.lookup(purchase.seller&.account_created_ip)
      country_name = geo_ip_location&.country_name
      state_code = geo_ip_location&.region_name
    end

    country_name = Compliance::Countries.find_by_name(country_name)&.common_name || "Uncategorized"
    state_name = Compliance::Countries::USA.subdivisions[state_code]&.name || "Uncategorized"

    [country_name, state_name]
  end

  private
    # Applies a chargeback (sign = -1) or chargeback-reversal (sign = +1) fee adjustment to
    # the aggregates, bucketed by the same creator location as the sales leg.
    def apply_chargeback_fee(purchase, sign, country_data, state_data)
      fee_cents = sign * purchase.fee_cents_for_chargeback_reporting
      return if fee_cents.zero?

      country_name, state_name = determine_country_name_and_state_name(purchase)

      country_data[country_name] ||= 0
      country_data[country_name] += fee_cents

      if country_name == "United States"
        state_data[state_name] ||= 0
        state_data[state_name] += fee_cents
      end
    end

    # Memoizes each seller's compliance-info rows once, then selects the
    # applicable one per purchase in Ruby. This keeps the exact
    # `created_at < purchase.created_at` semantics of the original per-purchase
    # query (so intraday compliance changes are still honored) while issuing
    # only one query per seller instead of one per purchase.
    def compliance_info_for(purchase)
      @compliance_infos_by_seller ||= {}
      infos = (@compliance_infos_by_seller[purchase.seller_id] ||= purchase.seller
        .user_compliance_infos
        .where.not("country IS NULL AND business_country IS NULL")
        .order(:created_at)
        .to_a)

      infos.select { |info| info.created_at < purchase.created_at }.last
    end
end
