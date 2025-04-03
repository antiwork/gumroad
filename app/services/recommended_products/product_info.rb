# frozen_string_literal: true

class RecommendedProducts::ProductInfo
  attr_accessor :recommended_by, :recommender_model_name, :target
  attr_reader :product, :affiliate_id

  def initialize(product, affiliate_id: nil)
    @product = product
    @affiliate_id = affiliate_id
  end
end
