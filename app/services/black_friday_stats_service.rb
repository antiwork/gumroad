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
      offer_codes = OfferCode.alive.where(code: SearchProducts::BLACK_FRIDAY_CODE)
      active_offer_codes = offer_codes.reject(&:inactive?)
      percentages = active_offer_codes.filter_map(&:amount_percentage)

      {
        active_deals_count: active_offer_codes.size,
        # Includes codes that have since expired: revenue already earned during the sale still counts.
        revenue_cents: Purchase.offer_code_statistics.where(offer_code_id: offer_codes.select(:id)).sum(:price_cents),
        average_discount_percentage: percentages.empty? ? 0 : (percentages.sum.to_f / percentages.size).round
      }
    end
  end
end
