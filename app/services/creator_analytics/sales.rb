# frozen_string_literal: true

class CreatorAnalytics::Sales
  SEARCH_OPTIONS = Purchase::CHARGED_SALES_SEARCH_OPTIONS.merge(
    exclude_refunded: false,
    exclude_unreversed_chargedback: false,
  )

  VALID_INTERVALS = %w[day hour].freeze
  # Hourly buckets multiply fast (24 per day per product), so hourly analytics are
  # limited to short date ranges to keep Elasticsearch bucket counts sane.
  MAX_HOURLY_DATE_RANGE_DAYS = 7

  def initialize(user:, products:, dates:, interval: "day")
    raise ArgumentError, "interval must be one of: #{VALID_INTERVALS.join(", ")}" unless VALID_INTERVALS.include?(interval)
    if interval == "hour" && (dates.last - dates.first).to_i > MAX_HOURLY_DATE_RANGE_DAYS
      raise ArgumentError, "date range cannot exceed #{MAX_HOURLY_DATE_RANGE_DAYS} days for the hour interval"
    end

    @user = user
    @products = products
    @dates = dates
    @interval = interval
    @query = PurchaseSearchService.new(SEARCH_OPTIONS).body[:query]
    @query[:bool][:filter] << { terms: { product_id: @products.map(&:id) } }
    @query[:bool][:must] << CreatorAnalytics::DateQuery.day_range(field: :created_at, start_date: @dates.first, end_date: @dates.last, timezone: @user.timezone)
  end

  def by_product_and_date
    sources = [
      { product_id: { terms: { field: "product_id" } } },
      date_histogram_source
    ]
    paginate(sources:).each_with_object({}) do |bucket, result|
      key = [
        bucket["key"]["product_id"],
        bucket_date_key(bucket)
      ]
      result[key] = merge_date_bucket(result[key], bucket)
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
      date_histogram_source
    ]

    paginate(sources:).each_with_object({}) do |bucket, hash|
      key = [
        bucket["key"]["product_id"],
        bucket["key"]["referrer_domain"],
        bucket_date_key(bucket),
      ]
      hash[key] = merge_date_bucket(hash[key], bucket)
    end
  end

  private
    # At a DST fall-back the same local hour occurs twice, so two Elasticsearch
    # buckets can map onto the same wall-clock key. Combine them into one bucket
    # for that hour instead of letting the second silently overwrite the first.
    def merge_date_bucket(existing, bucket)
      count = bucket["doc_count"]
      total = bucket["total"]["value"].to_i
      return { count:, total: } if existing.nil?

      { count: existing[:count] + count, total: existing[:total] + total }
    end

    def date_histogram_source
      histogram = { time_zone: @user.timezone_id, field: "created_at", calendar_interval: @interval }
      # Hourly buckets are keyed by epoch milliseconds and formatted in Ruby (see
      # bucket_date_key). An offset-less hour string is ambiguous at a DST fall-back,
      # and Elasticsearch rejects the query when the formatted composite after_key no
      # longer parses back to the same instant.
      histogram[:format] = "yyyy-MM-dd" unless @interval == "hour"
      { date: { date_histogram: histogram } }
    end

    def bucket_date_key(bucket)
      value = bucket["key"]["date"]
      return value unless @interval == "hour"

      # Convert the bucket's epoch timestamp to a wall-clock hour in the seller's
      # timezone, e.g. "2026-07-16T13:00". The two instants of a DST fall-back hour
      # map onto the same key; merge_date_bucket combines them.
      Time.at(value.to_i / 1000).in_time_zone(@user.timezone).strftime("%Y-%m-%dT%H:%M")
    end

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
        timeout: "60s",
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
