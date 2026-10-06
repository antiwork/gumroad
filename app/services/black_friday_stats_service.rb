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
      percentages = active_offer_codes.filter_map do |offer_code|
        # Tiered codes keep their percentages in ownership_duration_tiers and leave
        # amount_percentage at its placeholder, so use the top tier, matching
        # configured_discount_for_display.
        if offer_code.tiered?
          offer_code.normalized_ownership_duration_tiers.map { _1["amount_percentage"] }.max
        else
          offer_code.amount_percentage
        end
      end

      {
        active_deals_count: active_offer_codes.size,
        # Includes codes that have since expired: revenue already earned during the sale still counts.
        revenue_cents: Purchase.offer_code_statistics.where(offer_code_id: offer_codes.select(:id)).sum(:price_cents),
        average_discount_percentage: percentages.empty? ? 0 : (percentages.sum.to_f / percentages.size).round
      }
    end
  end
end
