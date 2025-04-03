# frozen_string_literal: true

class RecommendedProducts::CheckoutService < RecommendedProducts::BaseService
  def self.fetch_for_cart(purchaser:, cart_product_ids:, recommender_model_name:, limit:, recommendation_type: nil)
    new(
      purchaser:,
      cart_product_ids:,
      recommender_model_name:,
      recommended_by: RecommendationType::GUMROAD_MORE_LIKE_THIS_RECOMMENDATION,
      target: Product::Layout::PROFILE,
      limit:,
      recommendation_type:,
    ).result
  end

  def self.fetch_for_receipt(purchaser:, receipt_product_ids:, recommender_model_name:, limit:)
    new(
      purchaser:,
      cart_product_ids: receipt_product_ids,
      recommender_model_name:,
      recommended_by: RecommendationType::GUMROAD_RECEIPT_RECOMMENDATION,
      target: Product::Layout::PROFILE,
      limit:,
    ).result
  end

  include SearchProducts

  def result
    recommended_products = fetch_recommended_products(for_seller_ids: affiliated_users.present? ? nil : cart_seller_ids)
    recommended_products = recommended_products.includes(:direct_affiliates) if affiliated_users.present?
    recommended_products = recommended_products.includes(:taxonomy, user: [:alive_bank_accounts]) if global_affiliate.present?
    recommended_products = recommended_products.alive.not_archived
    recommended_products = recommended_products.reject(&:rated_as_adult?) if affiliated_users.present? && Link.includes(:user).where(id: cart_product_ids).none?(&:rated_as_adult?)

    product_infos = recommended_products.filter_map do |product|
      direct_affiliate_id = affiliated_users.present? ? product.direct_affiliates.find { affiliated_users.ids.include?(_1.affiliate_user_id) }&.external_id_numeric : nil

      if cart_seller_ids&.include?(product.user_id) || direct_affiliate_id.present? || (global_affiliate.present? && product.user.not_disable_global_affiliate? && product.recommendable?)
        RecommendedProducts::ProductInfo.new(
          product,
          affiliate_id: direct_affiliate_id || global_affiliate&.external_id_numeric
        )
      end
    end.take(limit)

    if product_infos.length < limit && cart_seller_ids.present?
      missing_results_count = limit - product_infos.length
      search_result = search_products(
        {
          size: missing_results_count,
          sort: ProductSortKey::FEATURED,
          user_id: cart_seller_ids,
          is_alive_on_profile: true,
          exclude_ids: (exclude_product_ids + product_infos.map { _1.product.id }).uniq
        }
      )
      products = search_result[:products].includes(ProductPresenter::ASSOCIATIONS_FOR_CARD)

      product_infos += products.map { RecommendedProducts::ProductInfo.new(_1) }
    end

    build_result(product_infos:)
  end

  private
    def cart_seller_ids
      return [] if recommendation_type == User::RecommendationType::NO_RECOMMENDATIONS
      @_seller_ids ||= begin
        users = Link.joins(:user)
        users = users.where.not(user: { recommendation_type: User::RecommendationType::NO_RECOMMENDATIONS }) if !recommendation_type
        users
          .where(id: cart_product_ids)
          .select(:user_id)
          .distinct
          .pluck(:user_id)
      end
    end

    def affiliated_users
      @_affiliate_users ||= begin
        recommendation_types = [
          User::RecommendationType::GUMROAD_AFFILIATES_PRODUCTS,
          User::RecommendationType::DIRECTLY_AFFILIATED_PRODUCTS
        ]
        return User.none if cart_seller_ids.blank? || recommendation_type && !recommendation_types.include?(recommendation_type)

        users = User.where(id: cart_seller_ids)
        users = users.where(recommendation_type: recommendation_types) if !recommendation_type
        users
      end
    end

    def global_affiliate
      @_global_affiliate ||= affiliated_users
        .find { (recommendation_type || _1.recommendation_type) == User::RecommendationType::GUMROAD_AFFILIATES_PRODUCTS }
        &.global_affiliate
    end
end
