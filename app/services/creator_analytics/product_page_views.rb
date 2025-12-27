# frozen_string_literal: true

class CreatorAnalytics::ProductPageViews
  def initialize(user:, products:, dates:)
    @user = user
    @products = products
    @dates = dates
    @query = {
      bool: {
        filter: [{ terms: { product_id: @products.map(&:id) } }],
        must: [{ range: { timestamp: { time_zone: @user.timezone_id, gte: @dates.first.to_s, lte: @dates.last.to_s } } }]
      }
    }
  end

  def by_product_and_date
    sources = [
      { product_id: { terms: { field: "product_id" } } },
      { date: { date_histogram: { time_zone: @user.timezone_id, field: "timestamp", calendar_interval: "day", format: "yyyy-MM-dd" } } }
    ]
    paginate(sources:).each_with_object({}) do |bucket, result|
      key = [
        bucket["key"]["product_id"],
        bucket["key"]["date"]
      ]
      result[key] = bucket["doc_count"]
    end
  end

  def by_product_and_country_and_state
    sources = [
      { product_id: { terms: { field: "product_id" } } },
      { country: { terms: { field: "country", missing_bucket: true } } },
      { state: { terms: { field: "state", missing_bucket: true } } }
    ]
    paginate(sources:).each_with_object({}) do |bucket, result|
      key = [
        bucket["key"]["product_id"],
        bucket["key"]["country"].presence,
        bucket["key"]["state"].presence,
      ]
      result[key] = bucket["doc_count"]
    end
  end

  def by_product_and_referrer_and_date
    sources = [
      { product_id: { terms: { field: "product_id" } } },
      { referrer_domain: { terms: { field: "referrer_domain" } } },
      { date: { date_histogram: { time_zone: @user.timezone_id, field: "timestamp", calendar_interval: "day", format: "yyyy-MM-dd" } } }
    ]
    paginate(sources:).each_with_object(Hash.new(0)) do |bucket, hash|
      key = [
        bucket["key"]["product_id"],
        bucket["key"]["referrer_domain"],
        bucket["key"]["date"],
      ]
      hash[key] = bucket["doc_count"]
    end
  end

  private
    def paginate(sources:)
      after_key = nil
      body = build_body(sources)
      buckets = []
      loop do
        body[:aggs][:composite_agg][:composite][:after] = after_key if after_key
        response_agg = ProductPageView.search(body).aggregations.composite_agg
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
        aggs: { composite_agg: { composite: { size: ES_MAX_BUCKET_SIZE, sources: } } }
      }
    end
end
