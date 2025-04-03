# frozen_string_literal: true

class UpdateCachedSalesRelatedProductsInfosJob
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :low, lock: :until_executed

  # We don't need to store the fact that a (popular) product is related to 100k other ones,
  # especially when many of these have been only purchased a small number of times,
  # which will end up making no difference in the final recommendations.
  # However, the higher limit, the larger the "breadth" of the recommendations will be: A user who already
  # purchased a lot of similar products will still be able to be recommended new, lesser known products.
  RELATED_PRODUCTS_LIMIT = 500

  def perform(product_id)
    product = Link.find(product_id)

    counts = SalesRelatedProductsInfo.related_product_ids_and_sales_counts(product.id, limit: RELATED_PRODUCTS_LIMIT)
    cache = CachedSalesRelatedProductsInfo.find_or_create_by!(product:)
    cache.update!(counts:)
  end
end
