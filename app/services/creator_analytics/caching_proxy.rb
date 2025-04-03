# frozen_string_literal: true

class CreatorAnalytics::CachingProxy
  include Formatters::Helpers
  include Formatters::ByDate
  include Formatters::ByState
  include Formatters::ByReferral

  def initialize(user)
    @user = user
  end

  # Proxy for cached values of CreatorAnalytics::Web#by_(date|state|referral)
  # - Gets the cached values for all dates in one SELECT operation
  # - If some are missing, run original several-day-spanning method of the missing ranges
  # - Returns the merged data, optionally grouped by "month"
  def data_for_dates(start_date, end_date, by: :date, options: {})
    dates = requested_dates(start_date, end_date)
    data = if use_cache?
      data_for_dates = fetch_data_for_dates(dates, by:)
      compiled_data = compile_data_for_dates_and_fill_missing(data_for_dates, by:)
      public_send("merge_data_by_#{by}", compiled_data, dates)
    else
      analytics_data(dates.first, dates.last, by:)
    end

    data = public_send("group_#{by}_data_by_#{options[:group_by]}", data, options) if by.in?([:date, :referral]) && options[:group_by].to_s.in?(["day", "month"])
    data
  end

  # Generates cached data for all possible dates for a seller
  def generate_cache
    return if @user.suspended?
    first_sale_created_at = @user.first_sale_created_at_for_analytics
    return if first_sale_created_at.nil?

    first_sale_date = first_sale_created_at.in_time_zone(@user.timezone).to_date
    # We fetch data for all dates up to the last date that `fetch_data` will cache.
    dates = (first_sale_date .. last_date_to_cache).to_a

    ActiveRecord::Base.connection.cache do
      [:date, :state, :referral].each do |type|
        Makara::Context.release_all
        uncached_dates(dates, by: type).each do |date|
          Makara::Context.release_all
          fetch_data(date, by: type)
        end
      end
    end
  end

  # Regenerate cached data for a date, useful when a purchase from a past day was refunded
  def overwrite_cache(date, by: :date)
    return if date < PRODUCT_EVENT_TRACKING_STARTED_DATE
    return if date > last_date_to_cache
    return unless use_cache?

    ComputedSalesAnalyticsDay.upsert_data_from_key(
      cache_key_for_data(date, by:),
      analytics_data(date, date, by:)
    )
  end

  private
    def use_cache?
      @_use_cache = LargeSeller.where(user: @user).exists?
    end

    def cache_key_for_data(date, by: :date)
      "#{user_cache_key}_by_#{by}_for_#{date}"
    end

    # Today, from the user's timezone point of view
    def today_date
      Time.now.in_time_zone(@user.timezone).to_date
    end

    def last_date_to_cache
      today_date - 2.days
    end

    # If the way analytics are calculated changed (e.g. an underlying method is changed),
    # or the underlying data (purchases, events) has been unusually modified (e.g. directly via SQL),
    # we may want to recalculate all cached analytics.
    # The simplest way of doing so is to bump the analytics cache version:
    #   key = RedisKey.seller_analytics_cache_version; $redis.set(key, $redis.get(key) + 1)
    # You'll probably then want to generate the cache for large sellers (see `generate_cache`).
    def user_cache_key
      return @_user_cache_key if @_user_cache_key
      version = $redis.get(RedisKey.seller_analytics_cache_version) || 0
      @_user_cache_key = "seller_analytics_v#{version}_user_#{@user.id}_#{@user.timezone}"
    end

    # Returns array of dates missing from the cache
    def uncached_dates(dates, by: :date)
      dates_to_keys = dates.index_with { |date| cache_key_for_data(date, by:) }
      existing_keys = ComputedSalesAnalyticsDay.where(key: dates_to_keys.values).pluck(:key)
      missing_keys = dates_to_keys.values - existing_keys
      dates_to_keys.invert.values_at(*missing_keys)
    end

    # Direct proxy for CreatorAnalytics::Web
    def analytics_data(start_date, end_date, by: :date)
      CreatorAnalytics::Web.new(user: @user, dates: (start_date .. end_date).to_a).public_send("by_#{by}")
    end

    # Fetches and caches the analytics data for one specific date
    def fetch_data(date, by: :date)
      # Invalidating the cache for Today's analytics is complex,
      # so we're currently not caching Today's data at all.
      # We're also not caching "yesterday" because we're internally not acknowledging DST when querying
      # via Elasticsearch, and being off by an hour can result in caching incomplete stats.
      return analytics_data(date, date, by:) if date > last_date_to_cache

      ComputedSalesAnalyticsDay.fetch_data_from_key(cache_key_for_data(date, by:)) do
        analytics_data(date, date, by:)
      end
    end

    # Constrains the date range coming from the web browser
    # - It can't start after Today or before the user creation date
    # - It can't end after Today
    # - It will always return at least one day
    def requested_dates(start_date, end_date)
      user_created_date = @user.created_at.in_time_zone(@user.timezone).to_date
      constrained_start = start_date.clamp(user_created_date, today_date)
      constrained_end = end_date.clamp(constrained_start, today_date)
      (constrained_start .. constrained_end).to_a
    end

    # Takes an array of dates, returns a hash with matching stored data, or nil if missing.
    def fetch_data_for_dates(dates, by: :date)
      keys_to_dates = dates.index_by { |date| cache_key_for_data(date, by:) }
      existing_data_with_keys = ComputedSalesAnalyticsDay.read_data_from_keys(keys_to_dates.keys)
      existing_data_with_keys.transform_keys { |key| keys_to_dates[key] }
    end

    # Takes an hash of { date => (data | nil), }, returns an array of data for all days.
    def compile_data_for_dates_and_fill_missing(data_for_dates, by: :date)
      missing_date_ranges = find_missing_date_ranges(data_for_dates)
      data_for_dates.flat_map do |date, day_data|
        next day_data if day_data
        missing_range = missing_date_ranges.find { |range| range.begin == date }
        analytics_data(missing_range.begin, missing_range.end, by:) if missing_range
      end.compact.map(&:with_indifferent_access)
    end

    # Returns contiguous missing dates as ranges.
    # In: { date => (data or nil), ... }
    # Out: [ (from .. to), ... ]
    def find_missing_date_ranges(data)
      hash_result = data.each_with_object({}) do |(date, value), hash|
        next if value
        hash[ hash.key(date - 1) || date ] = date
      end
      hash_result.map { |array| Range.new(*array) }
    end
end
