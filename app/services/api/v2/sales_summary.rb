# frozen_string_literal: true

class Api::V2::SalesSummary
  VALID_GROUPS = %w[product day week month hour].freeze

  def initialize(seller:, from:, to:, group_by: nil)
    # The controller returns a friendly 400 for this case; the guard here protects
    # any future caller from requesting an unbounded number of hourly buckets.
    if group_by == "hour" && (to - from).to_i > CreatorAnalytics::Sales::MAX_HOURLY_DATE_RANGE_DAYS
      raise ArgumentError, "date range cannot exceed #{CreatorAnalytics::Sales::MAX_HOURLY_DATE_RANGE_DAYS} days when grouping by hour"
    end

    @seller = seller
    @from = from
    @to = to
    @group_by = group_by
  end

  def as_json(*)
    result = summary_from_search
    result.merge!(
      currency: Currency::USD,
      from: @from.to_s,
      to: @to.to_s,
    )
    result[:breakdown] = breakdown if @group_by.present?
    result
  end

  private
    def summary_from_search
      search_result = PurchaseSearchService.search(base_search_options.merge(track_total_hits: true, aggs: metric_aggs))
      summary_from_result(search_result.results.total, search_result.aggregations)
    end

    def breakdown
      buckets = paginated_breakdown_buckets
      @products_by_id = @seller.links.where(id: buckets.map { _1["key"]["product_id"].to_i }.uniq).index_by(&:id) if @group_by == "product"
      items = buckets.map { breakdown_item(_1) }
      return items.sort_by { [-_1[:gross_cents], _1[:label].to_s] } if @group_by == "product"

      items = merge_items_sharing_a_key(items) if @group_by == "hour"
      items.sort_by { _1[:key] }
    end

    # At a DST fall-back the same local hour occurs twice, so two Elasticsearch
    # buckets can map onto the same wall-clock key. Merge them into a single item
    # for that hour so consumers never see duplicate keys.
    def merge_items_sharing_a_key(items)
      items.group_by { _1[:key] }.map do |_key, group|
        group.reduce do |merged, item|
          merged.merge(
            gross_cents: merged[:gross_cents] + item[:gross_cents],
            net_cents: merged[:net_cents] + item[:net_cents],
            units: merged[:units] + item[:units],
            refunded_cents: merged[:refunded_cents] + item[:refunded_cents],
            refunded_units: merged[:refunded_units] + item[:refunded_units],
          )
        end
      end
    end

    def paginated_breakdown_buckets
      after_key = nil
      body = breakdown_body
      buckets = []

      loop do
        body[:aggs][:breakdown][:composite][:after] = after_key if after_key
        response = Purchase.search(body).aggregations.breakdown
        buckets += response.buckets
        break if response.buckets.size < ES_MAX_BUCKET_SIZE

        after_key = response["after_key"]
      end

      buckets
    end

    def breakdown_body
      {
        query: PurchaseSearchService.new(base_search_options).query,
        size: 0,
        aggs: {
          breakdown: {
            composite: { size: ES_MAX_BUCKET_SIZE, sources: breakdown_sources },
            aggs: metric_aggs
          }
        }
      }
    end

    def base_search_options
      Purchase::CHARGED_SALES_SEARCH_OPTIONS.merge(
        seller: @seller,
        exclude_refunded: false,
        exclude_unreversed_chargedback: false,
        created_on_or_after: CreatorAnalytics::DateQuery.day_start(@from, timezone: @seller.timezone),
        created_before: CreatorAnalytics::DateQuery.day_start(@to + 1.day, timezone: @seller.timezone),
        size: 0,
      )
    end

    def metric_aggs
      {
        gross_cents: { sum: { field: "price_cents" } },
        refunded_cents: { sum: { field: "amount_refunded_cents" } },
        refunded_units: { filter: { range: { amount_refunded_cents: { gt: 0 } } } },
      }
    end

    def breakdown_sources
      case @group_by
      when "product"
        [{ product_id: { terms: { field: "product_id" } } }]
      when "day", "week", "month", "hour"
        histogram = { time_zone: @seller.timezone_id, field: "created_at", calendar_interval: @group_by }
        # Hourly buckets are keyed by epoch milliseconds and formatted in Ruby (see
        # bucket_date_key). An offset-less hour string is ambiguous at a DST fall-back,
        # and Elasticsearch rejects the query when the formatted composite after_key no
        # longer parses back to the same instant.
        histogram[:format] = date_format unless @group_by == "hour"
        [{ date: { date_histogram: histogram } }]
      end
    end

    def date_format
      @group_by == "month" ? "yyyy-MM" : "yyyy-MM-dd"
    end

    def bucket_date_key(bucket)
      value = bucket["key"]["date"]
      return value unless @group_by == "hour"

      # Convert the bucket's epoch timestamp to a wall-clock hour in the seller's
      # timezone, e.g. "2026-07-16T13:00". The two instants of a DST fall-back hour
      # map onto the same key; merge_items_sharing_a_key combines them.
      Time.at(value.to_i / 1000).in_time_zone(@seller.timezone).strftime("%Y-%m-%dT%H:%M")
    end

    def breakdown_item(bucket)
      item = summary_from_result(bucket["doc_count"], bucket)
      if @group_by == "product"
        product = products_by_id[bucket["key"]["product_id"].to_i]
        item.merge(key: product&.external_id || bucket["key"]["product_id"].to_s, label: product&.name)
      else
        date_key = bucket_date_key(bucket)
        item.merge(key: date_key, label: date_key)
      end
    end

    def summary_from_result(units, aggregation)
      gross_cents = aggregation["gross_cents"]["value"].to_i
      refunded_cents = aggregation["refunded_cents"]["value"].to_i
      {
        gross_cents:,
        net_cents: gross_cents - refunded_cents,
        units:,
        refunded_cents:,
        refunded_units: aggregation["refunded_units"]["doc_count"],
      }
    end

    def products_by_id
      @products_by_id ||= {}
    end
end
