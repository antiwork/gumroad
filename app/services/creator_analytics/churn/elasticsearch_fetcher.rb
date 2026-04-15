# frozen_string_literal: true

# Runs the ES-facing layer for churn: builds scoped queries and pagination to fetch
# cancellations (with recurring revenue), new subscriptions, and active baselines.
# Assumes subscription activity lives in the purchases index; relies on
# Purchase::CHARGED_SALES_SEARCH_OPTIONS and the original-subscription flag to filter scope.
class CreatorAnalytics::Churn::ElasticsearchFetcher
  attr_reader :seller, :products, :date_window

  def initialize(seller:, products:, date_window:)
    @seller = seller
    @products = products
    @date_window = date_window
  end

  # Sample output: { [1, Date.parse("2024-05-01")] => { churned_count: 2, revenue_lost_cents: 5000 } }
  def churn_events
    return {} if product_ids.empty?

    query = base_query
    query[:bool][:must] << { exists: { field: "subscription_cancelled_at" } }
    query[:bool][:filter] << {
      range: {
        subscription_cancelled_at: {
          time_zone: date_window.timezone_id,
          gte: date_window.start_date.to_s,
          lte: date_window.end_date.to_s
        }
      }
    }

    sources = composite_sources(field: "subscription_cancelled_at")
    aggs = {
      churned_customers: { cardinality: { field: "subscription_id" } },
      revenue_lost_cents: { sum: { field: "monthly_recurring_revenue" } }
    }
    buckets = paginate(query:, sources:, aggs:)

    buckets.each_with_object({}) do |bucket, result|
      product_id = bucket["key"]["product_id"]
      date = parse_bucket_date(bucket["key"]["date"])
      result[[product_id, date]] = {
        churned_count: bucket.dig("churned_customers", "value").to_i,
        revenue_lost_cents: bucket.dig("revenue_lost_cents", "value").to_i
      }
    end
  end

  # Sample output: { [1, Date.parse("2024-05-01")] => 3 }
  def new_subscriptions
    return {} if product_ids.empty?

    query = base_query
    query[:bool][:filter] << {
      range: {
        created_at: {
          time_zone: date_window.timezone_id,
          gte: date_window.start_date.to_s,
          lte: date_window.end_date.to_s
        }
      }
    }

    sources = composite_sources(field: "created_at")
    aggs = {
      new_customers: { cardinality: { field: "subscription_id" } }
    }
    buckets = paginate(query:, sources:, aggs:)

    buckets.each_with_object({}) do |bucket, result|
      product_id = bucket["key"]["product_id"]
      date = parse_bucket_date(bucket["key"]["date"])
      result[[product_id, date]] = bucket.dig("new_customers", "value").to_i
    end
  end

  # Sample output: { 1 => 20 }
  def initial_active_counts
    return {} if product_ids.empty?

    query = base_query
    start_boundary = date_window.start_date.to_s
    query[:bool][:filter] << { range: { created_at: { lt: start_boundary, time_zone: date_window.timezone_id } } }
    query[:bool][:should] ||= []
    query[:bool][:should] << { bool: { must_not: { exists: { field: "subscription_deactivated_at" } } } }
    query[:bool][:should] << { range: { subscription_deactivated_at: { time_zone: date_window.timezone_id, gt: start_boundary } } }
    query[:bool][:minimum_should_match] = 1

    sources = [
      { product_id: { terms: { field: "product_id" } } }
    ]
    aggs = {
      active_subscribers: { cardinality: { field: "subscription_id" } }
    }
    buckets = paginate(query:, sources:, aggs:)

    buckets.each_with_object(Hash.new(0)) do |bucket, result|
      product_id = bucket["key"]["product_id"]
      result[product_id] = bucket.dig("active_subscribers", "value").to_i
    end
  end

  private
    def product_ids
      @product_ids ||= products.map(&:id)
    end

    def base_query
      query = search_body[:query].deep_dup
      query[:bool][:filter] ||= []
      query[:bool][:must] ||= []
      query[:bool][:filter] << { term: { seller_id: seller.id } }
      query[:bool][:filter] << { terms: { product_id: product_ids } }
      query[:bool][:must] << { term: { selected_flags: "is_original_subscription_purchase" } }
      query
    end

    def search_body
      @search_body ||= PurchaseSearchService.new(Purchase::CHARGED_SALES_SEARCH_OPTIONS).body
    end

    def composite_sources(field:)
      [
        { product_id: { terms: { field: "product_id" } } },
        {
          date: {
            date_histogram: {
              field: field,
              calendar_interval: "day",
              format: "yyyy-MM-dd",
              time_zone: date_window.timezone_id
            }
          }
        }
      ]
    end

    def paginate(query:, sources:, aggs:)
      body = {
        query: query,
        size: 0,
        aggs: {
          composite_agg: {
            composite: { size: ES_MAX_BUCKET_SIZE, sources: sources },
            aggs: aggs
          }
        }
      }

      buckets = []
      after_key = nil

      loop do
        body[:aggs][:composite_agg][:composite][:after] = after_key if after_key
        response = Purchase.search(body).aggregations.composite_agg
        buckets.concat(response.buckets)
        break if response.buckets.size < ES_MAX_BUCKET_SIZE
        after_key = response.after_key
      end

      buckets
    end

    def parse_bucket_date(raw_value)
      return Date.parse(raw_value) if raw_value.is_a?(String)

      Time.at(raw_value / 1000.0).in_time_zone(seller.timezone).to_date
    end
end
