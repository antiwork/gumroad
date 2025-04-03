# frozen_string_literal: true

class RecommendedProductsService
  MODELS = ["sales"]
  MODELS.each do |key|
    const_set("MODEL_#{key.upcase}", key)
  end

  # Returns a ActiveRecord::Relation of ordered products records.
  #
  # NOTES:
  # 1- Because it returns an ActiveRecord::Relation, the result can be used to preload associated records:
  # Example: `.fetch(...).includes(:product_review_stat).as_json`
  #
  # 2- To be able to guarantee the correct order of products returned,
  # the order is "hardcoded" in the relation's SQL query; please do not reorder (including with `find_each`).
  #
  # There is no guarantee of any products being returned at all.
  def self.fetch(
    model:, # one of MODELS
    ids: [],
    exclude_ids: [],
    user_ids: nil,
    number_of_results: 10
  )
    case model
    when MODEL_SALES
      return Link.none if user_ids&.length == 0
      recommended_products = SalesRelatedProductsInfo.related_products(ids, limit: number_of_results)
      recommended_products = recommended_products.where(user_id: user_ids) unless user_ids.nil?
      recommended_products.alive.where.not(id: exclude_ids)
    end
  end
end
