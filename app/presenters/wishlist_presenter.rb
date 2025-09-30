# frozen_string_literal: true

class WishlistPresenter
  include Rails.application.routes.url_helpers
  include Pagy::Backend

  attr_reader :wishlist

  PER_PAGE = 20
  private_constant :PER_PAGE

  def initialize(wishlist:)
    @wishlist = wishlist
  end

  def self.library_props(wishlists:, is_wishlist_creator: true)
    counts = wishlists.joins(:alive_wishlist_products).group("wishlists.id").count
    wishlists.map do |wishlist|
      new(wishlist:).library_props(product_count: counts[wishlist.id] || 0, is_wishlist_creator:)
    end
  end

  def self.cards_props(wishlists:, pundit_user:, layout: nil, recommended_by: nil)
    following_wishlists = pundit_user&.seller ? WishlistFollower.alive.where(follower_user: pundit_user.seller, wishlist_id: wishlists.map(&:id)).pluck(:wishlist_id) : []
    wishlists.includes(ASSOCIATIONS_FOR_CARD).map do |wishlist|
      new(wishlist:).card_props(pundit_user:, following: following_wishlists.include?(wishlist.id), layout:, recommended_by:)
    end
  end

  def public_items(request:, pundit_user:, recommended_by: nil, page: 1)
    paginated_public_items(request:, pundit_user:, recommended_by:, page:)
  end

  def library_props(product_count:, is_wishlist_creator: true)
    {
      id: wishlist.external_id,
      name: wishlist.name,
      url: wishlist_url(wishlist.url_slug, host: wishlist.user.subdomain_with_protocol),
      product_count:,
      creator: is_wishlist_creator ? nil : {
        name: wishlist.user.name_or_username,
        profile_url: wishlist.user.profile_url,
        avatar_url: wishlist.user.avatar_url
      },
      discover_opted_out: (wishlist.discover_opted_out? if is_wishlist_creator),
    }
  end

  def listing_props(product: nil)
    {
      id: wishlist.external_id,
      name: wishlist.name
    }.merge(product ? selections_in_wishlist_props(product:) : {})
  end

  def public_props(request:, pundit_user:, recommended_by: nil)
    items_with_pagination = paginated_public_items(request:, pundit_user:, recommended_by:, page: 1)

    {
      id: wishlist.external_id,
      name: wishlist.name,
      description: wishlist.description,
      url: Rails.application.routes.url_helpers.wishlist_url(wishlist.url_slug, host: wishlist.user.subdomain_with_protocol),
      user: wishlist.user != pundit_user&.seller ? {
        name: wishlist.user.name_or_username,
        profile_url: wishlist.user.profile_url,
        avatar_url: wishlist.user.avatar_url,
      } : nil,
      following: pundit_user&.seller ? wishlist.followed_by?(pundit_user.seller) : false,
      can_follow: Feature.active?(:follow_wishlists, pundit_user&.seller) && pundit_user&.seller != wishlist.user,
      can_edit: pundit_user&.user ? Pundit.policy!(pundit_user, wishlist).update? : false,
      discover_opted_out: pundit_user&.user && Pundit.policy!(pundit_user, wishlist).update? ? wishlist.discover_opted_out? : nil,
      checkout_enabled: wishlist.alive_wishlist_products.available_to_buy.any?,
    }.merge(items_with_pagination)
  end

  ASSOCIATIONS_FOR_CARD = [
    :user,
    {
      alive_wishlist_products: {
        product: [:thumbnail_alive, :display_asset_previews]
      }
    }
  ].freeze

  def card_props(pundit_user:, following:, layout: nil, recommended_by: nil)
    thumbnails = wishlist.alive_wishlist_products.last(4).map { product_thumbnail(_1.product) }
    thumbnails = [thumbnails.last].compact if thumbnails.size < 4
    {
      id: wishlist.external_id,
      url: wishlist_url(wishlist.url_slug, host: wishlist.user.subdomain_with_protocol, layout:, recommended_by:),
      name: wishlist.name,
      description: wishlist.description,
      seller: UserPresenter.new(user: wishlist.user).author_byline_props,
      thumbnails:,
      product_count: wishlist.alive_wishlist_products.size,
      follower_count: wishlist.follower_count,
      following:,
      can_follow: Feature.active?(:follow_wishlists, pundit_user&.seller) && pundit_user&.seller != wishlist.user,
    }
  end

  private
    def paginated_public_items(request:, pundit_user:, recommended_by:, page:)
      pagination, wishlist_products = pagy(wishlist.alive_wishlist_products, page:, limit: PER_PAGE)

      paginated_products = wishlist_products
      .includes(product: ProductPresenter::ASSOCIATIONS_FOR_CARD)
      .map do |wishlist_product|
        public_item_props(
          wishlist_product:,
          request:,
          current_seller: pundit_user&.seller,
          recommended_by:
        )
      end

      {
        items: paginated_products,
        pagination: PagyPresenter.new(pagination).metadata,
      }
    end

    def product_thumbnail(product)
      { url: product.thumbnail_or_cover_url, native_type: product.native_type }
    end

    def selections_in_wishlist_props(product:)
      {
        selections_in_wishlist: wishlist.alive_wishlist_products.filter_map do |wishlist_product|
          if wishlist_product.product_id == product.id
            {
              variant_id: (ObfuscateIds.encrypt(wishlist_product.variant_id) if wishlist_product.variant_id),
              recurrence: wishlist_product.recurrence,
              rent: wishlist_product.rent,
              quantity: wishlist_product.quantity
            }
          end
        end
      }
    end

    def public_item_props(wishlist_product:, request:, current_seller:, recommended_by:)
      {
        id: wishlist_product.external_id,
        product: ProductPresenter.card_for_web(
          product: wishlist_product.product,
          request:,
          recommended_by: recommended_by || RecommendationType::WISHLIST_RECOMMENDATION,
          affiliate_id: wishlist.user.global_affiliate.external_id_numeric.to_s,
        ),
        option: wishlist_product.variant&.to_option,
        recurrence: wishlist_product.recurrence,
        quantity: wishlist_product.quantity,
        rent: wishlist_product.rent,
        created_at: wishlist_product.created_at,
        purchasable: wishlist_product.product.alive? && wishlist_product.product.published?,
        giftable: wishlist_product.product.can_gift? && wishlist.user != current_seller,
      }
    end
end
