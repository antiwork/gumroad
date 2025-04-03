# frozen_string_literal: true

class RecommendedProducts::DiscoverService < RecommendedProducts::BaseService
  def self.fetch(purchaser:, cart_product_ids:, recommender_model_name:)
    new(
      purchaser:,
      cart_product_ids:,
      recommender_model_name:,
      recommended_by: RecommendationType::GUMROAD_PRODUCTS_FOR_YOU_RECOMMENDATION,
      target: Product::Layout::DISCOVER,
      limit: NUMBER_OF_RESULTS,
    ).product_infos
  end

  def product_infos
    recommended_products = fetch_recommended_products(for_seller_ids: nil).alive.not_archived.reject(&:rated_as_adult?)
    product_infos = recommended_products.map do
      RecommendedProducts::ProductInfo.new(_1)
    end.take(limit)

    build_result(product_infos:)
  end
end
