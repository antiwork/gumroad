# frozen_string_literal: true

class WishlistsController < ApplicationController
  include CustomDomainConfig, DiscoverCuratedProducts, FindWishlist

  before_action :authenticate_user!, except: :show
  after_action :verify_authorized, except: :show
  before_action :hide_layouts, only: :show
  before_action :find_wishlist, only: :show

  def index
    authorize Wishlist

    wishlists_props = WishlistPresenter.library_props(wishlists: current_seller.wishlists.alive)

    if request.format.json?
      wishlists = current_seller.wishlists.alive.includes(:products).by_external_ids(params[:ids])
      render json: WishlistPresenter.cards_props(wishlists:, pundit_user:, layout: Product::Layout::PROFILE)
    else
      render inertia: "Wishlists/Index",
             props: inertia_props(
               wishlists: wishlists_props,
               reviews_page_enabled: Feature.active?(:reviews_page, current_seller),
               following_wishlists_enabled: Feature.active?(:follow_wishlists, current_seller)
             )
    end
  end

  def create
    authorize Wishlist

    wishlist = current_seller.wishlists.create!

    render json: { wishlist: WishlistPresenter.new(wishlist:).listing_props }, status: :created
  end

  def show
    wishlist_presenter = WishlistPresenter.new(wishlist: @wishlist)

    render inertia: "Wishlist/Show",
           props: inertia_props(**wishlist_presenter.public_props(request:, pundit_user:, recommended_by: params[:recommended_by]))
  end

  def update
    wishlist = current_seller.wishlists.alive.find_by_external_id!(params[:id])
    authorize wishlist

    if wishlist.update(params.require(:wishlist).permit(:name, :description, :discover_opted_out))
      head :no_content
    else
      render json: { error: wishlist.errors.full_messages.first }, status: :unprocessable_entity
    end
  end

  def destroy
    wishlist = current_seller.wishlists.alive.find_by_external_id!(params[:id])
    authorize wishlist

    wishlist.transaction do
      wishlist.mark_deleted!
      wishlist.wishlist_followers.alive.update_all(deleted_at: Time.current)
    end

    head :no_content
  end
end
