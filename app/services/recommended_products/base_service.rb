# frozen_string_literal: true

class RecommendedProducts::BaseService
  NUMBER_OF_RESULTS = 40

  def initialize(purchaser:, cart_product_ids:, recommender_model_name:, recommended_by:, target:, limit:, recommendation_type: nil)
    @purchaser = purchaser
    @cart_product_ids = cart_product_ids
    @recommender_model_name = recommender_model_name
    @recommended_by = recommended_by
    @target = target
    @limit = limit
    @recommendation_type = recommendation_type
  end

  def build_result(product_infos:)
    product_infos.map do |product_info|
      product_info.recommended_by = recommended_by
      product_info.recommender_model_name = recommender_model_name
      product_info.target = target
      product_info
    end
  end

  private
    attr_reader :purchaser, :cart_product_ids, :recommender_model_name, :recommended_by, :target, :limit, :request, :recommendation_type

    def fetch_recommended_products(for_seller_ids:)
      associated_ids = find_associated_product_ids(limit: associated_product_ids_limit)

      ids = if associated_ids.size >= 4
        associated_ids.sample((associated_ids.size * 0.5).to_i)
      else
        associated_ids
      end

      RecommendedProductsService.fetch(
        model: recommender_model_name,
        ids:,
        exclude_ids: exclude_product_ids,
        user_ids: for_seller_ids,
        number_of_results: NUMBER_OF_RESULTS,
      )
    end

    def all_associated_product_ids
      @_associated_product_ids ||= find_associated_product_ids
    end

    def find_associated_product_ids(limit: nil)
      purchased_products = purchaser&.purchased_products&.order(succeeded_at: :desc)
      if limit.present?
        cart_product_ids.take(limit) | (purchased_products&.limit(limit)&.ids || [])
      else
        cart_product_ids | (purchased_products&.ids || [])
      end
    end

    def exclude_product_ids
      @_exclude_product_ids ||= \
        all_associated_product_ids +
        BundleProduct.alive.where(bundle_id: all_associated_product_ids).distinct.pluck(:product_id)
    end

    def associated_product_ids_limit
      ($redis.get(RedisKey.recommended_products_associated_product_ids_limit) || 100).to_i
    end
end
