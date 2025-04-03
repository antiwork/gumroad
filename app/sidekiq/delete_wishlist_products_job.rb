# frozen_string_literal: true

class DeleteWishlistProductsJob
  include Sidekiq::Job
  sidekiq_options queue: :low

  def perform(product_id)
    product = Link.find(product_id)
    return unless product.deleted? # user undid product deletion

    product.wishlist_products.alive.find_each(&:mark_deleted!)
  end
end
