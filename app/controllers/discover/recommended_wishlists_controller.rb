# frozen_string_literal: true

class Discover::RecommendedWishlistsController < ApplicationController
  def index
    wishlists = RecommendedWishlistsService.fetch(
      limit: 4,
      current_seller:,
      curated_product_ids: (params[:curated_product_ids] || []).map { ObfuscateIds.decrypt(_1) },
      taxonomy_id: params[:taxonomy].present? ? Taxonomy.find_by_path(params[:taxonomy].split("/")).id : nil
    )
    render json: WishlistPresenter.cards_props(
      wishlists:,
      pundit_user:,
      layout: Product::Layout::DISCOVER,
      recommended_by: RecommendationType::GUMROAD_DISCOVER_WISHLIST_RECOMMENDATION,
    )
  end
end
