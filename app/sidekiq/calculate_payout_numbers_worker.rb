# frozen_string_literal: true

class CalculatePayoutNumbersWorker
  include Sidekiq::Job
  sidekiq_options retry: 2, queue: :default

  def perform
    now = Time.now.in_time_zone("America/Los_Angeles")
    beginning_of_last_week = now.prev_week
    end_of_last_week = beginning_of_last_week.end_of_week
    search_result = PurchaseSearchService.new(
      price_greater_than: 0,
      state: "successful",
      size: 0,
      exclude_unreversed_chargedback: true,
      exclude_refunded: true,
      exclude_bundle_product_purchases: true,
      created_on_or_after: beginning_of_last_week,
      created_on_or_before: end_of_last_week,
      aggs: {
        total_made: {
          sum: { field: "price_cents" }
        }
      }
    ).process
    total_made_in_usd = search_result.aggregations.total_made.value / 100.to_d

    $redis.set(RedisKey.prev_week_payout_usd, total_made_in_usd.to_i)
  end
end
