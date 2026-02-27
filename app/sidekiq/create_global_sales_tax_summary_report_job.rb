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

  def perform(month, year)
    raise ArgumentError, "Invalid month" unless month.in?(1..12)
    raise ArgumentError, "Invalid year" unless year.in?(2014..3200)

    start_date = Date.new(year, month).beginning_of_day
    end_date = Date.new(year, month).end_of_month.end_of_day

    aggregation = Hash.new { |h, k| h[k] = { gmv_cents: 0, order_count: 0, tax_collected_cents: 0 } }

    timeout_seconds = ($redis.get(RedisKey.create_global_sales_tax_summary_report_job_max_execution_time_seconds) || 1.hour).to_i
    WithMaxExecutionTime.timeout_queries(seconds: timeout_seconds) do
      purchases_scope = Purchase.successful
        .not_fully_refunded
        .not_chargedback_or_chargedback_reversed
        .where.not(stripe_transaction_id: nil)
        .where("gumroad_tax_cents > 0")
        .where("purchases.created_at BETWEEN ? AND ?", start_date, end_date)
        .where(charge_processor_id: [nil, *ChargeProcessor.charge_processor_ids])

      rows = aggregation_query_rows(purchases_scope)
      unresolved_us_tuple_keys = []

      rows.each do |country, ip_country, zip_code, state, ip_state,
                    country_key, ip_country_key, zip_key, state_key, ip_state_key,
                    gmv, count, tax|
        raw_name = country.presence || ip_country.presence
        country_name = resolve_country_name(raw_name)
        state_code = case country_name
                     when "United States"
                       resolved = UsZipCodes.identify_state_code(zip_code)
                       if resolved.nil?
                         unresolved_us_tuple_keys << [country_key, ip_country_key, zip_key, state_key, ip_state_key]
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

        bucket = aggregation[[country_name, state_code]]
        bucket[:gmv_cents] += gmv.to_i
        bucket[:order_count] += count.to_i
        bucket[:tax_collected_cents] += tax.to_i
      end

      # US purchases with zip codes not in UsZipCodes need individual GeoIp lookup for state resolution.
      resolve_geoip_fallback_purchases(purchases_scope, unresolved_us_tuple_keys, aggregation)
    end

    write_and_upload_csv(aggregation, month, year)
  end

  private
    def aggregation_query_rows(purchases_scope)
      key_sqls = BINARY_SAFE_KEY_COLUMNS.values

      purchases_scope
        .joins(<<~SQL)
          LEFT JOIN (
            SELECT purchase_id,
                   SUM(total_transaction_cents) AS refund_total_cents,
                   SUM(gumroad_tax_cents) AS refund_tax_cents
            FROM refunds
            WHERE purchase_id IN (
              #{purchases_scope.where(stripe_partially_refunded: true).select(:id).to_sql}
            )
            GROUP BY purchase_id
          ) refund_sums ON purchases.stripe_partially_refunded = 1
                        AND refund_sums.purchase_id = purchases.id
        SQL
        .group(*key_sqls.map { |sql| Arel.sql(sql) })
        .pluck(
          Arel.sql("ANY_VALUE(purchases.country)"),
          Arel.sql("ANY_VALUE(purchases.ip_country)"),
          Arel.sql("ANY_VALUE(purchases.zip_code)"),
          Arel.sql("ANY_VALUE(purchases.state)"),
          Arel.sql("ANY_VALUE(purchases.ip_state)"),
          *key_sqls.map { |sql| Arel.sql(sql) },
          Arel.sql("SUM(GREATEST(purchases.total_transaction_cents - COALESCE(refund_sums.refund_total_cents, 0), 0))"),
          Arel.sql("COUNT(*)"),
          Arel.sql("SUM(GREATEST(purchases.gumroad_tax_cents - COALESCE(refund_sums.refund_tax_cents, 0), 0))")
        )
    end

    def resolve_geoip_fallback_purchases(purchases_scope, unresolved_us_tuple_keys, aggregation)
      return if unresolved_us_tuple_keys.empty?

      conn = ActiveRecord::Base.connection
      key_names = BINARY_SAFE_KEY_COLUMNS.keys

      combined_condition_sql = unresolved_us_tuple_keys.map do |tuple_values|
        conditions = key_names.zip(tuple_values).map do |col, value|
          "#{BINARY_SAFE_KEY_COLUMNS[col]} = #{conn.quote(value)}"
        end
        "(#{conditions.join(' AND ')})"
      end.join(" OR ")

      fallback_scope = purchases_scope.where(Arel.sql(combined_condition_sql))

      fallback_refunds = Refund.where(purchase_id: fallback_scope.where(stripe_partially_refunded: true).select(:id))
        .group(:purchase_id)
        .pluck(:purchase_id, Arel.sql("SUM(refunds.total_transaction_cents)"), Arel.sql("SUM(refunds.gumroad_tax_cents)"))
        .to_h { |pid, total, tax| [pid, { total: total.to_i, tax: tax.to_i }] }

      fallback_scope.select(:id, :ip_address, :total_transaction_cents, :gumroad_tax_cents, :stripe_partially_refunded)
        .find_each do |purchase|
          state_code = GeoIp.lookup(purchase.ip_address)&.region_name || ""
          refund = fallback_refunds[purchase.id] if purchase.stripe_partially_refunded?
          bucket = aggregation[["United States", state_code]]
          bucket[:gmv_cents] += net_cents(purchase.total_transaction_cents, refund&.dig(:total))
          bucket[:order_count] += 1
          bucket[:tax_collected_cents] += net_cents(purchase.gumroad_tax_cents, refund&.dig(:tax))
        end
    end

    def write_and_upload_csv(aggregation, month, year)
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
      s3_object.upload_file(temp_file)
      s3_signed_url = s3_object.presigned_url(:get, expires_in: 1.week.to_i).to_s

      AccountingMailer.global_sales_tax_summary_report(month, year, s3_signed_url).deliver_now
      SlackMessageWorker.perform_async("payments", "Global Sales Tax Summary Report", "Global sales tax summary report for #{year}-#{month} is ready - #{s3_signed_url}", "green")
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

    def net_cents(gross_cents, refunded_cents)
      [gross_cents - refunded_cents.to_i, 0].max
    end
end
