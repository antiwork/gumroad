# frozen_string_literal: true

class CreatorAnalytics::Sales
  SEARCH_OPTIONS = Purchase::CHARGED_SALES_SEARCH_OPTIONS.merge(
    exclude_refunded: false,
    exclude_unreversed_chargedback: false,
  )

  def initialize(user:, products:, dates:)
    @user = user
    @products = products
    @dates = dates
    @query = PurchaseSearchService.new(SEARCH_OPTIONS).body[:query]
    @query[:bool][:filter] << { terms: { product_id: @products.map(&:id) } }
    @query[:bool][:must] << { range: { created_at: { time_zone: @user.timezone_id, gte: @dates.first.to_s, lte: @dates.last.to_s } } }
  end

  def by_product_and_date
    sources = [
      { product_id: { terms: { field: "product_id" } } },
      { date: { date_histogram: { time_zone: @user.timezone_id, field: "created_at", calendar_interval: "day", format: "yyyy-MM-dd" } } }
    ]
    paginate(sources:).each_with_object({}) do |bucket, result|
      key = [
        bucket["key"]["product_id"],
        bucket["key"]["date"]
      ]
      result[key] = { count: bucket["doc_count"], total: bucket["total"]["value"].to_i }
    end
  end

  def by_product_and_country_and_state
    sources = [
      { product_id: { terms: { field: "product_id" } } },
      { country: { terms: { field: "ip_country", missing_bucket: true } } },
      { state: { terms: { field: "ip_state", missing_bucket: true } } }
    ]
    paginate(sources:).each_with_object({}) do |bucket, result|
      key = [
        bucket["key"]["product_id"],
        bucket["key"]["country"].presence,
        bucket["key"]["state"].presence,
      ]
      result[key] = { count: bucket["doc_count"], total: bucket["total"]["value"].to_i }
    end
  end

  def by_product_and_referrer_and_date
    sources = [
      { product_id: { terms: { field: "product_id" } } },
      { referrer_domain: { terms: { field: "referrer_domain" } } },
      { date: { date_histogram: { time_zone: @user.timezone_id, field: "created_at", calendar_interval: "day", format: "yyyy-MM-dd" } } }
    ]

    paginate(sources:).each_with_object(Hash.new(0)) do |bucket, hash|
      key = [
        bucket["key"]["product_id"],
        bucket["key"]["referrer_domain"],
        bucket["key"]["date"],
      ]
      hash[key] = { count: bucket["doc_count"], total: bucket["total"]["value"].to_i }
    end
  end

  private
    def paginate(sources:)
      after_key = nil
      body = build_body(sources)
      buckets = []
      loop do
        body[:aggs][:composite_agg][:composite][:after] = after_key if after_key
        response_agg = Purchase.search(body).aggregations.composite_agg
        buckets += response_agg.buckets
        break if response_agg.buckets.size < ES_MAX_BUCKET_SIZE
        after_key = response_agg["after_key"]
      end
      buckets
    end

    def build_body(sources)
      {
        query: @query,
        size: 0,
        aggs: {
          composite_agg: {
            composite: { size: ES_MAX_BUCKET_SIZE, sources: },
            aggs: {
              price_cents_total: { sum: { field: "price_cents" } },
              amount_refunded_cents_total: { sum: { field: "amount_refunded_cents" } },
              chargedback_agg: {
                filter: { term: { not_chargedback_or_chargedback_reversed: false } },
                aggs: {
                  price_cents_total: { sum: { field: "price_cents" } },
                }
              },
              total: {
                bucket_script: {
                  buckets_path: {
                    price_cents_total: "price_cents_total",
                    amount_refunded_cents_total: "amount_refunded_cents_total",
                    chargedback_price_cents_total: "chargedback_agg>price_cents_total",
                  },
                  script: "params.price_cents_total - params.amount_refunded_cents_total - params.chargedback_price_cents_total"
                }
              }
            }
          }
        }
      }
    end
end
