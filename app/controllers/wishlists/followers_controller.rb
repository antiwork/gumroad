# frozen_string_literal: true

class Wishlists::FollowersController < ApplicationController
  before_action :authenticate_user!, except: :unsubscribe
  after_action :verify_authorized, except: :unsubscribe
  before_action { e404 if Feature.inactive?(:follow_wishlists, current_seller) }

  def create
    wishlist = Wishlist.find_by_external_id!(params[:wishlist_id])

    authorize WishlistFollower

    wishlist_follower = wishlist.wishlist_followers.build(follower_user: current_seller)

    if wishlist_follower.save
      head :created
    else
      render json: { error: wishlist_follower.errors.full_messages.first }, status: :unprocessable_entity
    end
  end

  def destroy
    wishlist = Wishlist.find_by_external_id!(params[:wishlist_id])
    wishlist_follower = wishlist.wishlist_followers.alive.find_by(follower_user: current_seller)

    e404 if wishlist_follower.blank?

    authorize wishlist_follower
    wishlist_follower.mark_deleted!

    head :no_content
  end

  def unsubscribe
    wishlist_follower = WishlistFollower.find_by_external_id!(params[:follower_id])
    wishlist_follower.mark_deleted!

    flash[:notice] = "You are no longer following #{wishlist_follower.wishlist.name}."
    redirect_to wishlist_url(wishlist_follower.wishlist.url_slug, host: wishlist_follower.wishlist.user.subdomain_with_protocol), allow_other_host: true
  end
end
