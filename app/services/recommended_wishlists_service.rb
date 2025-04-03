# frozen_string_literal: true

class RecommendedWishlistsService
  def self.fetch(limit:, current_seller:, curated_product_ids: [], taxonomy_id: nil)
    scope = Wishlist.where(recommendable: true).order(recent_follower_count: :desc)
    scope = scope.where.not(user_id: current_seller.id) if current_seller.present?

    return scope.limit(limit) if curated_product_ids.blank? && taxonomy_id.blank?

    matching_wishlists = Wishlist.from(scope.limit(10_000), :wishlists)
    matching_wishlists = matching_wishlists.joins(:wishlist_products).where(wishlist_products: { product_id: curated_product_ids }) if curated_product_ids.present?
    matching_wishlists = matching_wishlists.joins(wishlist_products: :product).where(links: { taxonomy_id: }) if taxonomy_id.present?
    matching_wishlists = matching_wishlists.distinct.limit(limit).to_a

    missing_count = limit - matching_wishlists.count
    if taxonomy_id.blank? && missing_count > 0 && missing_count < limit
      matching_wishlists += scope.where.not(id: matching_wishlists.pluck(:id)).limit(missing_count)
    end

    ids = matching_wishlists.pluck(:id)
    Wishlist.where(id: ids).order(Arel.sql("FIELD(id, #{ids.map { ActiveRecord::Base.connection.quote(_1) }.join(',')})"))
  end
end
