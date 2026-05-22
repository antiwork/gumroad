# frozen_string_literal: true

class Api::V2::SalesSummary
  VALID_GROUPS = %w[product day week month].freeze

  def initialize(seller:, from:, to:, group_by: nil)
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

      items.sort_by { _1[:key] }
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
      when "day", "week", "month"
        [{ date: { date_histogram: { time_zone: @seller.timezone_id, field: "created_at", calendar_interval: @group_by, format: date_format } } }]
      end
    end

    def date_format
      @group_by == "month" ? "yyyy-MM" : "yyyy-MM-dd"
    end

    def breakdown_item(bucket)
      item = summary_from_result(bucket["doc_count"], bucket)
      if @group_by == "product"
        product = products_by_id[bucket["key"]["product_id"].to_i]
        item.merge(key: product&.external_id || bucket["key"]["product_id"].to_s, label: product&.name)
      else
        item.merge(key: bucket["key"]["date"], label: bucket["key"]["date"])
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
