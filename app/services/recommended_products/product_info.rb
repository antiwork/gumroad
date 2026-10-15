# frozen_string_literal: true

class RecommendedProducts::ProductInfo
  CO_PURCHASE = "co_purchase"
  CREATOR_FEATURED = "creator_featured"

  attr_accessor :recommended_by, :recommender_model_name, :target
  attr_reader :product, :affiliate_id, :source

  def initialize(product, source:, affiliate_id: nil)
    @product = product
    @source = source
    @affiliate_id = affiliate_id
  end

  def co_purchase?
    source == CO_PURCHASE
  end
end
