# frozen_string_literal: true

class Wishlists::FollowingController < ApplicationController
  before_action :authenticate_user!
  after_action :verify_authorized
  before_action { e404 if Feature.inactive?(:follow_wishlists, current_seller) }

  layout "inertia"

  def index
    authorize Wishlist

    set_meta_tag(title: "Following")
    wishlists_props = WishlistPresenter.library_props(
      wishlists: current_seller.alive_following_wishlists,
      is_wishlist_creator: false
    )

    render inertia: "Wishlists/Following/Index", props: {
      wishlists: wishlists_props,
      reviews_page_enabled: Feature.active?(:reviews_page, current_seller),
    }
  end
end
