# frozen_string_literal: true

class CreateGlobalSalesTaxSummaryReportJob
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :default, lock: :until_executed

  sidekiq_retries_exhausted do |job, exception|
    month, year = job["args"]
    AccountingMailer.global_sales_tax_summary_report_failed(
      month, year, exception.class.name, exception.message
    ).deliver_later
  end

  # GROUP BY uses HEX(CAST(... AS BINARY)) to prevent MySQL's case-insensitive collation
  # from silently merging rows like "USA" and "usa" — Ruby handles normalization instead.
  BINARY_SAFE_KEY_COLUMNS = {
    country: "COALESCE(HEX(CAST(purchases.country AS BINARY)), '__NULL__')",
    ip_country: "COALESCE(HEX(CAST(purchases.ip_country AS BINARY)), '__NULL__')",
    zip_code: "COALESCE(HEX(CAST(purchases.zip_code AS BINARY)), '__NULL__')",
    state: "COALESCE(HEX(CAST(purchases.state AS BINARY)), '__NULL__')",
    ip_state: "COALESCE(HEX(CAST(purchases.ip_state AS BINARY)), '__NULL__')"
  }.freeze
  QUERY_CHUNK_DAYS = 1

  def perform(month, year)
    raise ArgumentError, "Invalid month" unless month.in?(1..12)
    raise ArgumentError, "Invalid year" unless year.in?(2014..3200)

    job_started_at = monotonic_seconds
    start_date = Date.new(year, month).beginning_of_day
    end_date = Date.new(year, month).end_of_month.end_of_day

    aggregation = Hash.new { |h, k| h[k] = { gmv_cents: 0, order_count: 0, tax_collected_cents: 0 } }
    # Sales leg. not_chargedback_for_tax_reporting keeps, on top of the reversed (won)
    # chargebacks the old scope kept, event-dated chargebacks (see
    # Purchase::Reportable::CHARGEBACK_REPORTING_CUTOVER): their sale stays counted in the
    # purchase's own month while the clawback is subtracted by the chargeback legs below.
    # Chargebacks lost before the chargeback reporting cutover keep the legacy drop so
    # historical months regenerate as filed.
    base_scope = Purchase.successful
      .not_fully_refunded_for_tax_reporting
      .not_chargedback_for_tax_reporting
      .where.not(stripe_transaction_id: nil)
      .where("gumroad_tax_cents > 0")
      .where(charge_processor_id: [nil, *ChargeProcessor.charge_processor_ids])

    timeout_seconds = ($redis.get(RedisKey.create_global_sales_tax_summary_report_job_max_execution_time_seconds) || 1.hour).to_i
    Rails.logger.info("#{self.class.name}: start month=#{month} year=#{year} timeout_seconds=#{timeout_seconds} chunk_days=#{QUERY_CHUNK_DAYS}")

    chunk_index = 0
    WithMaxExecutionTime.timeout_queries(seconds: timeout_seconds) do
      each_month_chunk(start_date, end_date) do |chunk_start, chunk_end|
        chunk_index += 1
        chunk_started_at = monotonic_seconds

        purchases_scope = base_scope.where("purchases.created_at BETWEEN ? AND ?", chunk_start, chunk_end)
        stats = process_purchases_scope(purchases_scope, aggregation)

        Rails.logger.info(
          "#{self.class.name}: chunk_complete " \
          "month=#{month} year=#{year} index=#{chunk_index} " \
          "start_date=#{chunk_start.to_date} end_date=#{chunk_end.to_date} " \
          "grouped_rows=#{stats[:grouped_rows]} grouped_orders=#{stats[:grouped_orders]} total_orders=#{stats[:total_orders]} " \
          "refund_adjustment_groups=#{stats[:refund_adjustment_groups]} " \
          "unresolved_us_tuple_groups=#{stats[:unresolved_us_tuple_groups]} " \
          "fallback_purchases=#{stats[:fallback_purchases]} fallback_partial_refund_purchases=#{stats[:fallback_partial_refund_purchases]} " \
          "prefetch_seconds=#{stats[:prefetch_seconds]} aggregation_query_seconds=#{stats[:aggregation_query_seconds]} " \
          "fallback_seconds=#{stats[:fallback_seconds]} elapsed_seconds=#{elapsed_seconds(chunk_started_at)}"
        )
      end
    end

    Rails.logger.info(
      "#{self.class.name}: aggregation_complete " \
      "month=#{month} year=#{year} chunks=#{chunk_index} aggregated_locations=#{aggregation.size} elapsed_seconds=#{elapsed_seconds(job_started_at)}"
    )

    # Refund leg: refunds issued during the reported month are subtracted from the month's
    # totals, dated by the refund's date, regardless of when the original purchase happened.
    # (Pre-cutover refunds are instead netted into their purchase's month by the partial-refund
    # adjustments above — see Purchase::Reportable::REFUND_REPORTING_CUTOVER.)
    refund_leg_started_at = monotonic_seconds
    refund_count = apply_refund_leg(aggregation, start_date, end_date)
    Rails.logger.info(
      "#{self.class.name}: refund_leg_complete " \
      "month=#{month} year=#{year} refunds=#{refund_count} elapsed_seconds=#{elapsed_seconds(refund_leg_started_at)}"
    )

    # Chargeback legs: disputes formalized during the reported month subtract in this month
    # (dated by purchases.chargeback_date — the processor's dispute-formalized timestamp, so
    # no backfill), and disputes won during the month add back in this month (dated by the
    # Dispute row's won_at; real dispute rows only). Only event-dated chargebacks appear —
    # see Purchase::Reportable::CHARGEBACK_REPORTING_CUTOVER; earlier chargebacks keep the
    # legacy exclusion from the sales leg, so already-filed months regenerate as filed.
    #
    # Wrapped in the same max-execution-time guard as the sales aggregation above: these
    # legs are keyed on purchases.chargeback_date, which has no dedicated index (the only
    # chargeback_date index is the seller_id-led composite, unusable without a seller
    # filter), so each query scans purchases. The guard bounds a runaway scan the same way
    # it does for the sales leg, which this job already relies on to avoid the whole-month
    # aggregation timing out.
    chargeback_leg_started_at = monotonic_seconds
    chargeback_count = WithMaxExecutionTime.timeout_queries(seconds: timeout_seconds) do
      apply_chargeback_legs(aggregation, start_date, end_date)
    end
    Rails.logger.info(
      "#{self.class.name}: chargeback_leg_complete " \
      "month=#{month} year=#{year} chargeback_legs=#{chargeback_count} elapsed_seconds=#{elapsed_seconds(chargeback_leg_started_at)}"
    )

    write_and_upload_csv(aggregation, month, year)

    Rails.logger.info(
      "#{self.class.name}: complete " \
      "month=#{month} year=#{year} aggregated_locations=#{aggregation.size} elapsed_seconds=#{elapsed_seconds(job_started_at)}"
    )
  end

  private
    def monotonic_seconds
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def elapsed_seconds(started_at)
      (monotonic_seconds - started_at).round(2)
    end

    def each_month_chunk(start_date, end_date)
      chunk_start_date = start_date.to_date
      final_date = end_date.to_date

      while chunk_start_date <= final_date
        chunk_end_date = [chunk_start_date + (QUERY_CHUNK_DAYS - 1), final_date].min
        yield chunk_start_date.beginning_of_day, chunk_end_date.end_of_day
        chunk_start_date = chunk_end_date + 1
      end
    end

    def process_purchases_scope(purchases_scope, aggregation)
      prefetch_started_at = monotonic_seconds
      refund_adjustments = prefetch_partial_refund_adjustments(purchases_scope)
      prefetch_seconds = elapsed_seconds(prefetch_started_at)

      aggregation_query_started_at = monotonic_seconds
      rows = aggregation_query_rows(purchases_scope)
      aggregation_query_seconds = elapsed_seconds(aggregation_query_started_at)

      unresolved_us_tuple_keys = []
      grouped_orders = 0

      rows.each do |country, ip_country, zip_code, state, ip_state,
                    country_key, ip_country_key, zip_key, state_key, ip_state_key,
                    gmv, count, tax|
        raw_name = country.presence || ip_country.presence
        country_name = resolve_country_name(raw_name)
        group_key = [country_key, ip_country_key, zip_key, state_key, ip_state_key]

        state_code = case country_name
                     when "United States"
                       resolved = UsZipCodes.identify_state_code(zip_code)
                       if resolved.nil?
                         unresolved_us_tuple_keys << group_key
                         next
                       end
                       resolved
                     when "Canada"
                       resolve_canada_province(state, ip_state)
                     when "India"
                       resolve_india_state(ip_state)
                     else
                       ""
        end

        adj = refund_adjustments[group_key]
        bucket = aggregation[[country_name, state_code]]
        bucket[:gmv_cents] += net_cents(gmv.to_i, adj&.dig(:gmv_cents))
        bucket[:order_count] += count.to_i
        bucket[:tax_collected_cents] += net_cents(tax.to_i, adj&.dig(:tax_cents))
        grouped_orders += count.to_i
      end

      # US purchases with zip codes not in UsZipCodes need individual GeoIp lookup for state resolution.
      fallback_started_at = monotonic_seconds
      fallback_stats = resolve_geoip_fallback_purchases(purchases_scope, unresolved_us_tuple_keys, aggregation)
      fallback_seconds = elapsed_seconds(fallback_started_at)

      total_orders = grouped_orders + fallback_stats[:fallback_purchases]

      {
        grouped_rows: rows.size,
        grouped_orders: grouped_orders,
        total_orders: total_orders,
        refund_adjustment_groups: refund_adjustments.size,
        unresolved_us_tuple_groups: unresolved_us_tuple_keys.size,
        fallback_purchases: fallback_stats[:fallback_purchases],
        fallback_partial_refund_purchases: fallback_stats[:fallback_partial_refund_purchases],
        prefetch_seconds: prefetch_seconds,
        aggregation_query_seconds: aggregation_query_seconds,
        fallback_seconds: fallback_seconds,
      }
    end

    # Nets refund amounts into their purchase's own period — the LEGACY attribution, kept only
    # for refunds created before the refund reporting cutover so historical months regenerate
    # close to their as-filed numbers. Refunds created on/after the cutover are attributed to
    # the month the refund happened in by apply_refund_leg instead, so they must not also be
    # netted here (that would relieve the same tax twice).
    def prefetch_partial_refund_adjustments(purchases_scope)
      key_sqls = BINARY_SAFE_KEY_COLUMNS.values

      # Includes fully refunded purchases too, not just partially refunded ones: a pre-cutover
      # purchase whose refunds straddle the cutover ends up with stripe_refunded true (and
      # stripe_partially_refunded flipped back to false), yet its PRE-cutover refunds must
      # still be netted from its sale row here — only the post-cutover refund is offset by a
      # refund row in the refund's own period. refund_totals_by_purchase only sums pre-cutover
      # refunds, and a post-cutover purchase can't have any, so this stays exact.
      partial_purchases = purchases_scope
        .where("purchases.stripe_partially_refunded = TRUE OR purchases.stripe_refunded = TRUE")
        .pluck(
          :id,
          Arel.sql("purchases.total_transaction_cents"),
          Arel.sql("purchases.gumroad_tax_cents"),
          *key_sqls.map { |sql| Arel.sql(sql) }
        )
      return {} if partial_purchases.empty?

      refund_sums = refund_totals_by_purchase(partial_purchases.map(&:first))

      adjustments = Hash.new { |h, k| h[k] = { gmv_cents: 0, tax_cents: 0 } }

      partial_purchases.each do |id, gross_gmv, gross_tax, *group_keys|
        refund = refund_sums[id]
        next unless refund

        adj = adjustments[group_keys]
        adj[:gmv_cents] += [refund[:total], gross_gmv].min
        adj[:tax_cents] += [refund[:tax], gross_tax].min
      end

      adjustments
    end

    def aggregation_query_rows(purchases_scope)
      key_sqls = BINARY_SAFE_KEY_COLUMNS.values

      purchases_scope
        .group(*key_sqls.map { |sql| Arel.sql(sql) })
        .pluck(
          Arel.sql("ANY_VALUE(purchases.country)"),
          Arel.sql("ANY_VALUE(purchases.ip_country)"),
          Arel.sql("ANY_VALUE(purchases.zip_code)"),
          Arel.sql("ANY_VALUE(purchases.state)"),
          Arel.sql("ANY_VALUE(purchases.ip_state)"),
          *key_sqls.map { |sql| Arel.sql(sql) },
          Arel.sql("SUM(purchases.total_transaction_cents)"),
          Arel.sql("COUNT(*)"),
          Arel.sql("SUM(purchases.gumroad_tax_cents)")
        )
    end

    def resolve_geoip_fallback_purchases(purchases_scope, unresolved_us_tuple_keys, aggregation)
      return { fallback_purchases: 0, fallback_partial_refund_purchases: 0 } if unresolved_us_tuple_keys.empty?

      conn = ActiveRecord::Base.connection
      key_names = BINARY_SAFE_KEY_COLUMNS.keys

      combined_condition_sql = unresolved_us_tuple_keys.map do |tuple_values|
        conditions = key_names.zip(tuple_values).map do |col, value|
          "#{BINARY_SAFE_KEY_COLUMNS[col]} = #{conn.quote(value)}"
        end
        "(#{conditions.join(' AND ')})"
      end.join(" OR ")

      fallback_scope = purchases_scope.where(Arel.sql(combined_condition_sql))

      # Same widening as prefetch_partial_refund_adjustments: fully refunded purchases can
      # still carry pre-cutover refunds that must be netted from their sale amounts.
      fallback_refunds = refund_totals_by_purchase(
        fallback_scope.where("purchases.stripe_partially_refunded = TRUE OR purchases.stripe_refunded = TRUE").pluck(:id)
      )

      fallback_purchases = 0
      fallback_partial_refund_purchases = 0

      fallback_scope.select(:id, :ip_address, :total_transaction_cents, :gumroad_tax_cents, :stripe_partially_refunded, :stripe_refunded)
        .find_each do |purchase|
          state_code = GeoIp.lookup(purchase.ip_address)&.region_name || ""
          refund = fallback_refunds[purchase.id]
          bucket = aggregation[["United States", state_code]]
          bucket[:gmv_cents] += net_cents(purchase.total_transaction_cents, refund&.dig(:total))
          bucket[:order_count] += 1
          bucket[:tax_collected_cents] += net_cents(purchase.gumroad_tax_cents, refund&.dig(:tax))

          fallback_purchases += 1
          fallback_partial_refund_purchases += 1 if purchase.stripe_partially_refunded?
        end

      {
        fallback_purchases: fallback_purchases,
        fallback_partial_refund_purchases: fallback_partial_refund_purchases,
      }
    end

    def write_and_upload_csv(aggregation, month, year)
      write_started_at = monotonic_seconds
      Rails.logger.info("#{self.class.name}: csv_write_start month=#{month} year=#{year} aggregated_locations=#{aggregation.size}")

      temp_file = Tempfile.new
      temp_file.write(["Country", "State/Province", "GMV", "Number of orders", "Sales tax collected"].to_csv)

      aggregation.sort.each do |(country_name, state_code), data|
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

      upload_started_at = monotonic_seconds
      s3_object.upload_file(temp_file)
      s3_signed_url = s3_object.presigned_url(:get, expires_in: 1.week.to_i).to_s

      AccountingMailer.global_sales_tax_summary_report(month, year, s3_signed_url).deliver_now
      InternalNotificationWorker.perform_async("payments", "Global Sales Tax Summary Report", "Global sales tax summary report for #{year}-#{month} is ready - #{s3_signed_url}", "green")

      Rails.logger.info(
        "#{self.class.name}: csv_write_complete " \
        "month=#{month} year=#{year} aggregated_locations=#{aggregation.size} s3_report_key=#{s3_report_key} " \
        "upload_seconds=#{elapsed_seconds(upload_started_at)} elapsed_seconds=#{elapsed_seconds(write_started_at)}"
      )
    ensure
      temp_file&.close
    end

    def resolve_country_name(raw_name)
      return "Unknown" if raw_name.blank?

      normalized_country_names[raw_name]
    end

    def normalized_country_names
      @normalized_country_names ||= Hash.new do |hash, raw_name|
        country = Compliance::Countries.find_by_name(raw_name)
        hash[raw_name] = country&.common_name || raw_name
      end
    end

    def valid_canada_provinces
      @valid_canada_provinces ||= Compliance::Countries.subdivisions_for_select(Compliance::Countries::CAN.alpha2).map(&:first)
    end

    def resolve_canada_province(state, ip_state)
      if state.present? && state.in?(valid_canada_provinces)
        state
      elsif ip_state.present? && ip_state.in?(valid_canada_provinces)
        ip_state
      else
        ""
      end
    end

    def resolve_india_state(ip_state)
      raw_state = ip_state.to_s.strip.upcase
      Compliance::Countries.valid_indian_state?(raw_state) ? raw_state : ""
    end

    # Sums only PRE-CUTOVER refunds: these are the refunds still netted into their purchase's
    # period. Post-cutover refunds are handled by apply_refund_leg in the refund's own month.
    def refund_totals_by_purchase(purchase_ids)
      # .effective keeps failed-but-not-reversed refunds (the seller is still debited)
      # and drops reversed ones, matching the refunded sums everywhere else.
      Refund.effective.where(purchase_id: purchase_ids)
        .where("refunds.created_at < ?", Purchase::Reportable::REFUND_REPORTING_CUTOVER.beginning_of_day)
        .group(:purchase_id)
        .pluck(:purchase_id, Arel.sql("SUM(refunds.total_transaction_cents)"), Arel.sql("SUM(refunds.gumroad_tax_cents)"))
        .to_h { |pid, total, tax| [pid, { total: total.to_i, tax: tax.to_i }] }
    end

    # Subtracts refunds issued in [starts_at, ends_at] from the aggregation, bucketed by the
    # buyer location of the ORIGINAL purchase (resolved with the same rules as the sales leg),
    # dated by the refund's own date. The purchase-side filters mirror the sales leg's base
    # scope minus its date window, so a refund is only subtracted when its purchase's sale was
    # (or would have been) counted. Order counts are left untouched — the order still happened.
    def apply_refund_leg(aggregation, starts_at, ends_at)
      refund_count = 0

      Refund.for_tax_period_reporting(starts_at, ends_at)
        .joins(:purchase)
        .merge(
          Purchase.successful
            .not_chargedback_for_tax_reporting
            .where.not(purchases: { stripe_transaction_id: nil })
            .where("purchases.gumroad_tax_cents > 0")
            .where(purchases: { charge_processor_id: [nil, *ChargeProcessor.charge_processor_ids] })
        )
        .includes(:purchase)
        .find_each do |refund|
          purchase = refund.purchase
          country_name = resolve_country_name(purchase.country.presence || purchase.ip_country.presence)

          state_code = case country_name
                       when "United States"
                         UsZipCodes.identify_state_code(purchase.zip_code) ||
                           GeoIp.lookup(purchase.ip_address)&.region_name || ""
                       when "Canada"
                         resolve_canada_province(purchase.state, purchase.ip_state)
                       when "India"
                         resolve_india_state(purchase.ip_state)
                       else
                         ""
          end

          bucket = aggregation[[country_name, state_code]]
          bucket[:gmv_cents] -= refund.total_transaction_cents.to_i
          bucket[:tax_collected_cents] -= refund.gumroad_tax_cents.to_i
          refund_count += 1
        end

      refund_count
    end

    # Subtracts chargebacks whose dispute was formalized in [starts_at, ends_at] and adds back
    # disputes won inside the window, bucketed by the buyer location of the ORIGINAL purchase
    # (resolved with the same rules as the refund leg). Amounts are net of each purchase's
    # refunds (see Purchase::Reportable#total_cents_for_chargeback_reporting) — money already
    # returned by a refund was relieved by the refund's own path and is not clawed back again.
    # Order counts are left untouched — the order still happened. Returns the number of legs
    # applied.
    def apply_chargeback_legs(aggregation, starts_at, ends_at)
      leg_count = 0

      chargeback_purchase_filters(Purchase.chargebacks_for_tax_period_reporting(starts_at, ends_at))
        .find_each do |purchase|
          apply_chargeback_leg(aggregation, purchase, -1)
          leg_count += 1
        end

      chargeback_purchase_filters(Purchase.chargeback_reversals_for_tax_period_reporting(starts_at, ends_at))
        .find_each do |purchase|
          won_at = purchase.chargeback_reversal_reporting_date
          next unless won_at&.between?(starts_at, ends_at)

          apply_chargeback_leg(aggregation, purchase, 1)
          leg_count += 1
        end

      leg_count
    end

    # The sales leg's purchase filters minus its date window — a chargeback leg belongs to
    # the month of the dispute event (or the win), but must only appear when the purchase's
    # sale was (or would have been) counted by this report.
    def chargeback_purchase_filters(scope)
      scope
        .successful
        .where.not(stripe_transaction_id: nil)
        .where("purchases.gumroad_tax_cents > 0")
        .where(charge_processor_id: [nil, *ChargeProcessor.charge_processor_ids])
    end

    def apply_chargeback_leg(aggregation, purchase, sign)
      country_name = resolve_country_name(purchase.country.presence || purchase.ip_country.presence)

      state_code = case country_name
                   when "United States"
                     UsZipCodes.identify_state_code(purchase.zip_code) ||
                       GeoIp.lookup(purchase.ip_address)&.region_name || ""
                   when "Canada"
                     resolve_canada_province(purchase.state, purchase.ip_state)
                   when "India"
                     resolve_india_state(purchase.ip_state)
                   else
                     ""
      end

      bucket = aggregation[[country_name, state_code]]
      bucket[:gmv_cents] += sign * purchase.total_cents_for_chargeback_reporting
      bucket[:tax_collected_cents] += sign * purchase.gumroad_tax_cents_for_chargeback_reporting
    end

    def net_cents(gross_cents, refunded_cents)
      [gross_cents - refunded_cents.to_i, 0].max
    end
end
