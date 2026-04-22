# frozen_string_literal: true

class CreateGlobalSalesTaxSummaryReportJob
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :default, lock: :until_executed

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
    base_scope = Purchase.successful
      .not_fully_refunded
      .not_chargedback_or_chargedback_reversed
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

    def prefetch_partial_refund_adjustments(purchases_scope)
      key_sqls = BINARY_SAFE_KEY_COLUMNS.values

      partial_purchases = purchases_scope
        .where(stripe_partially_refunded: true)
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

      fallback_refunds = refund_totals_by_purchase(
        fallback_scope.where(stripe_partially_refunded: true).pluck(:id)
      )

      fallback_purchases = 0
      fallback_partial_refund_purchases = 0

      fallback_scope.select(:id, :ip_address, :total_transaction_cents, :gumroad_tax_cents, :stripe_partially_refunded)
        .find_each do |purchase|
          state_code = GeoIp.lookup(purchase.ip_address)&.region_name || ""
          refund = fallback_refunds[purchase.id] if purchase.stripe_partially_refunded?
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

    def refund_totals_by_purchase(purchase_ids)
      Refund.where(purchase_id: purchase_ids)
        .group(:purchase_id)
        .pluck(:purchase_id, Arel.sql("SUM(refunds.total_transaction_cents)"), Arel.sql("SUM(refunds.gumroad_tax_cents)"))
        .to_h { |pid, total, tax| [pid, { total: total.to_i, tax: tax.to_i }] }
    end

    def net_cents(gross_cents, refunded_cents)
      [gross_cents - refunded_cents.to_i, 0].max
    end
end
