# frozen_string_literal: true

class CalculateSaleNumbersWorker
  include Sidekiq::Job
  sidekiq_options retry: 2, queue: :default

  def perform
    calculate_stats_for_all_purchases
  end

  private
    def calculate_stats_for_all_purchases
      aggregations_body = {
        total_made: {
          sum: { field: "price_cents" }
        },
        number_of_creators: {
          cardinality: { field: "seller_id", precision_threshold: 40_000 } # 40k is the max threshold
          # When the actual cardinality is more than 40k expect a 0-2% error rate.
          # This would matter when updating values in real time. We should make sure that we don't store a value
          # less than what's already stored.
        }
      }
      search_options = {
        price_greater_than: 0,
        state: "successful",
        size: 0,
        exclude_unreversed_chargedback: true,
        exclude_refunded: true,
        exclude_bundle_product_purchases: true,
        aggs: aggregations_body
      }
      purchase_search = PurchaseSearchService.new(search_options)

      aggregations = purchase_search.process.aggregations
      total_made_in_usd = aggregations.total_made.value.to_i / 100
      number_of_creators = aggregations.number_of_creators.value

      $redis.set(RedisKey.total_made, total_made_in_usd)
      $redis.set(RedisKey.number_of_creators, number_of_creators)
    end
end
