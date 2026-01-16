# frozen_string_literal: true

class CreatorAnalytics::Churn
  InvalidDateRange = Class.new(StandardError)

  attr_reader :seller

  def initialize(seller:)
    @seller = seller
  end

  # Coordinator for churn analytics: scopes to subscription products, fetches churn/new/active
  # series via Elasticsearch, builds daily/monthly/summary payloads, and caches older ranges
  # like other sales analytics. Uses formula (cancellations ÷ (active-at-start + new))
  # and refreshes the most recent two days instead of caching them.
  def generate_data(start_date:, end_date:)
    current_date_window = CreatorAnalytics::Churn::DateWindow.new(
      seller:,
      product_scope:,
      start_date:,
      end_date:
    )

    if cacheable_range?(current_date_window)
      cached = read_cached_payload(current_date_window)
      return cached if cached
    end

    current_payload = build_payload(current_date_window)
    previous_date_window = build_previous_date_window(current_date_window)
    previous_payload = previous_date_window ? build_payload(previous_date_window) : nil

    payload = {
      metadata: {
        current_period: period_metadata(current_date_window),
        previous_period: previous_date_window ? period_metadata(previous_date_window) : nil,
        products: current_payload.dig(:metadata, :products) || []
      },
      data: {
        current_period: current_payload.fetch(:data),
        previous_period: previous_payload&.fetch(:data)
      }
    }
    write_cached_payload(current_date_window, payload) if cacheable_range?(current_date_window)
    payload
  end

  private
    def subscription_products
      product_scope.subscription_products
    end

    def product_scope
      @product_scope ||= CreatorAnalytics::Churn::ProductScope.new(seller:)
    end

    def build_payload(date_window)
      fetcher = CreatorAnalytics::Churn::ElasticsearchFetcher.new(
        seller:,
        products: subscription_products,
        date_window:
      )

      CreatorAnalytics::Churn::DatasetBuilder.new(
        product_scope:,
        date_window:,
        churn_events: fetcher.churn_events,
        new_subscriptions: fetcher.new_subscriptions,
        initial_active_counts: fetcher.initial_active_counts
      ).build
    end

    def use_cache?
      @use_cache ||= LargeSeller.where(user: seller).exists?
    end

    def cacheable_range?(date_window)
      return false unless use_cache?
      date_window.end_date <= cache_cutoff_date
    end

    def cache_cutoff_date
      @cache_cutoff_date ||= (Time.current.in_time_zone(seller.timezone).to_date - 2.days)
    end

    def read_cached_payload(date_window)
      record = ComputedSalesAnalyticsDay.find_by(key: cache_key_for(date_window))
      return unless record
      JSON.parse(record.data).deep_symbolize_keys
    end

    def write_cached_payload(date_window, payload)
      ComputedSalesAnalyticsDay.upsert_data_from_key(cache_key_for(date_window), payload)
    end

    def cache_key_for(date_window)
      version = $redis.get(RedisKey.seller_analytics_cache_version) || 0
      [
        "creator_analytics_churn",
        "payload",
        "v#{version}",
        "seller_#{seller.id}",
        seller.timezone,
        date_window.start_date,
        date_window.end_date
      ].join(":")
    end

    def build_previous_date_window(current_date_window)
      window_length = (current_date_window.end_date - current_date_window.start_date).to_i + 1
      previous_end = current_date_window.start_date - 1.day
      previous_start = previous_end - (window_length - 1).days
      return nil if previous_start < product_scope.earliest_analytics_date

      CreatorAnalytics::Churn::DateWindow.new(
        seller:,
        product_scope:,
        start_date: previous_start,
        end_date: previous_end
      )
    end

    def period_metadata(date_window)
      {
        start_date: date_window.start_date.to_s,
        end_date: date_window.end_date.to_s
      }
    end
end
