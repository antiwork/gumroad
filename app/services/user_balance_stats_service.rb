# frozen_string_literal: true

class UserBalanceStatsService
  include ActionView::Helpers::TranslationHelper
  include PayoutsHelper
  attr_reader :user
  DEFAULT_SALES_CACHING_THRESHOLD = 50_000

  def initialize(user:)
    @user = user
  end

  # The Payouts page reads only these two keys: it builds the past periods itself, off its own
  # paginated query. A payout period costs ~30 purchase aggregates (PayoutsHelper#payout_sales_data),
  # so the two readers here each skip the other's work.
  def fetch_payout_periods
    if should_use_cache?
      UpdateUserBalanceStatsCacheWorker.perform_async(user.id)
      cached = read_cache
      return cached.slice(:next_payout_period_data, :processing_payout_periods_data) if cached
    end
    payout_periods_stats
  end

  # The dashboard renders only these four scalars.
  # A cached blob missing :overview falls through instead of returning nil.
  def fetch_overview
    if should_use_cache?
      UpdateUserBalanceStatsCacheWorker.perform_async(user.id)
      cached_overview = read_cache&.dig(:overview)
      return cached_overview if cached_overview
    end
    overview_stats
  end

  def write_cache
    data = generate
    $redis.setex(cache_key, 48.hours.to_i, data.to_json)
  end

  def self.cacheable_users
    sales_threshold = $redis.get(RedisKey.balance_stats_sales_caching_threshold)
    sales_threshold ||= DEFAULT_SALES_CACHING_THRESHOLD
    excluded_user_ids = $redis.smembers(RedisKey.balance_stats_users_excluded_from_caching)
    users = User
      .joins(:large_seller)
      .where("large_sellers.sales_count >= ?", sales_threshold.to_i)
    users = users.where("large_sellers.user_id NOT IN (?)", excluded_user_ids) unless excluded_user_ids.empty?
    users
  end

  private
    # The cached blob is the union of what the two readers slice out of it.
    def generate
      {
        generated_at: Time.current,
        overview: overview_stats,
        **payout_periods_stats,
      }
    end

    def payout_periods_stats
      {
        next_payout_period_data:,
        processing_payout_periods_data: user.payments.processing.order("created_at DESC").map { payout_period_data(user, _1) },
      }
    end

    def overview_stats
      {
        balance: user.unpaid_balance_cents,
        last_seven_days_sales_total: user.sales_cents_total(after: 7.days.ago),
        last_28_days_sales_total: user.sales_cents_total(after: 28.days.ago),
        sales_cents_total: user.sales_cents_total,
      }
    end

    def read_cache
      data = $redis.get(cache_key)
      return nil unless data

      JSON.parse(data, symbolize_names: true)
    rescue JSON::ParserError => e
      Rails.logger.error("Failed to parse cached balance stats for user #{user.id}: #{e.message}")
      nil
    end

    def should_use_cache?
      @should_use_cache ||= self.class.cacheable_users.where(id: user.id).exists?
    end

    def cache_key
      "balance_stats_for_user_#{user.id}"
    end

    def next_payout_period_data
      return if user.payments
        .processing
        .where("JSON_UNQUOTE(JSON_EXTRACT(json_data, '$.type')) != ? OR JSON_EXTRACT(json_data, '$.type') IS NULL", Payouts::PAYOUT_TYPE_INSTANT)
        .any?

      payout_period_data(user)
    end
end
