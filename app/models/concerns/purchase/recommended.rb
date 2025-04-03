# frozen_string_literal: true

module Purchase::Recommended
  extend ActiveSupport::Concern

  def handle_recommended_purchase
    return unless successful? || preorder_authorization_successful? || is_free_trial_purchase?
    return if RecommendedPurchaseInfo.where(purchase_id: id).present?

    if RecommendationType.is_product_recommendation?(recommended_by)
      recommendation_type = RecommendationType::PRODUCT_RECOMMENDATION
      recommended_by_link = Link.find_by(unique_permalink: recommended_by)
    else
      recommendation_type = recommended_by
      recommended_by_link = nil
    end

    purchase_info_params = {
      purchase: self,
      recommended_link: link,
      recommended_by_link:,
      recommendation_type:,
      recommender_model_name:,
    }

    if was_discover_fee_charged?
      purchase_info_params[:discover_fee_per_thousand] = link.discover_fee_per_thousand
    end

    RecommendedPurchaseInfo.create!(purchase_info_params)
  end
end
