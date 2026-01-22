# frozen_string_literal: true

class BlackFridayStatsService
  CACHE_KEY = "black_friday_stats"
  CACHE_EXPIRATION = 10.minutes

  class << self
    def fetch_stats
      Rails.cache.fetch(CACHE_KEY, expires_in: CACHE_EXPIRATION) do
        calculate_stats
      end
    end

    def calculate_stats
      # TODO: Implement actual stats calculation
      # For now, returning placeholder values
      {
        active_deals_count: 0,
        revenue_cents: 0,
        average_discount_percentage: 0
      }
    end
  end
end
