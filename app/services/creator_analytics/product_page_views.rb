# frozen_string_literal: true

class CreatorAnalytics::ProductPageViews
  def initialize(user:, products:, dates:, interval: "day")
    # Interval validation and the hourly range bound mirror CreatorAnalytics::Sales
    # so both halves of the analytics dashboard obey the same policy.
    unless CreatorAnalytics::Sales::VALID_INTERVALS.include?(interval)
      raise ArgumentError, "interval must be one of: #{CreatorAnalytics::Sales::VALID_INTERVALS.join(", ")}"
    end
    if interval == "hour" && (dates.last - dates.first).to_i > CreatorAnalytics::Sales::MAX_HOURLY_DATE_RANGE_DAYS
      raise ArgumentError, "date range cannot exceed #{CreatorAnalytics::Sales::MAX_HOURLY_DATE_RANGE_DAYS} days for the hour interval"
    end

    @user = user
    @products = products
    @dates = dates
    @interval = interval
    @query = {
      bool: {
        filter: [{ terms: { product_id: @products.map(&:id) } }],
        must: [CreatorAnalytics::DateQuery.day_range(field: :timestamp, start_date: @dates.first, end_date: @dates.last, timezone: @user.timezone)]
      }
    }
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
      # At a DST fall-back the same local hour occurs twice, so two Elasticsearch
      # buckets can map onto the same wall-clock key; add instead of overwriting.
      result[key] = (result[key] || 0) + bucket["doc_count"]
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
      date_histogram_source
    ]
    paginate(sources:).each_with_object(Hash.new(0)) do |bucket, hash|
      key = [
        bucket["key"]["product_id"],
        bucket["key"]["referrer_domain"],
        bucket_date_key(bucket),
      ]
      # See by_product_and_date: the DST fall-back hour needs adding, not overwriting.
      hash[key] += bucket["doc_count"]
    end
  end

  private
    def date_histogram_source
      histogram = { time_zone: @user.timezone_id, field: "timestamp", calendar_interval: @interval }
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
      # timezone, e.g. "2026-07-16T13:00", matching CreatorAnalytics::Sales keys.
      Time.at(value.to_i / 1000).in_time_zone(@user.timezone).strftime("%Y-%m-%dT%H:%M")
    end

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
    rescue Elasticsearch::Transport::Transport::Errors::NotFound
      []
    end

    def build_body(sources)
      {
        query: @query,
        size: 0,
        timeout: "60s",
        aggs: { composite_agg: { composite: { size: ES_MAX_BUCKET_SIZE, sources: } } }
      }
    end
end
