# frozen_string_literal: true

class ReceiptPresenter::RecommendedProductsInfo
  # It should match the value from ApplicationController#set_recommender_model_name
  MODEL = RecommendedProductsService::MODELS.sample

  def initialize(chargeable)
    @chargeable = chargeable
    @purchaser = chargeable.purchaser
  end

  def title
    "Customers who bought #{receipt_product_ids.size == 1 ? "this item" : "these items"} also bought"
  end

  def products
    @_products ||= begin
      return [] if purchaser.blank?

      recommended_product_infos.map do |product_info|
        ProductPresenter.card_for_web(
          product: product_info.product,
          recommended_by: product_info.recommended_by,
          target: product_info.target,
          recommender_model_name: product_info.recommender_model_name,
          affiliate_id: product_info.affiliate_id,
          )
      end
    end
  end

  def present?
    products.present?
  end

  private
    RECOMMENDED_PRODUCTS_LIMIT = 2

    attr_reader :chargeable, :purchaser

    def receipt_product_ids
      @_receipt_product_ids ||= (bundle_purchases + chargeable.unbundled_purchases).map(&:link_id).uniq
    end

    def bundle_purchases
      chargeable.successful_purchases.select(&:is_bundle_purchase?)
    end

    def recommended_product_infos
      @recommended_product_infos ||= RecommendedProducts::CheckoutService.fetch_for_receipt(
        purchaser:,
        receipt_product_ids:,
        recommender_model_name: MODEL,
        limit: RECOMMENDED_PRODUCTS_LIMIT,
      )
    end
end
