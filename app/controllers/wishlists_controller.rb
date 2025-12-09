# frozen_string_literal: true

class WishlistsController < ApplicationController
  include CustomDomainConfig, DiscoverCuratedProducts

  before_action :authenticate_user!, except: :show
  after_action :verify_authorized, except: :show

  layout "inertia", only: [:index, :show]

  def index
    authorize Wishlist

    respond_to do |format|
      format.html do
        @title = Feature.active?(:follow_wishlists, current_seller) ? "Saved" : "Wishlists"
        wishlists_props = WishlistPresenter.library_props(wishlists: current_seller.wishlists.alive)

        render inertia: "Wishlists/Index", props: {
          wishlists: wishlists_props,
          reviews_page_enabled: Feature.active?(:reviews_page, current_seller),
          following_wishlists_enabled: Feature.active?(:follow_wishlists, current_seller),
        }
      end
      format.json do
        wishlists = current_seller.wishlists.alive.includes(:products).by_external_ids(params[:ids])
        render json: WishlistPresenter.cards_props(wishlists:, pundit_user:, layout: Product::Layout::PROFILE)
      end
    end
  end

  def create
    authorize Wishlist

    wishlist = current_seller.wishlists.create!

    render json: { wishlist: WishlistPresenter.new(wishlist:).listing_props }, status: :created
  end

  def show
    wishlist = user_by_domain(request.host).wishlists.alive.find_by_url_slug(params[:id])
    e404 if wishlist.blank?

    @user = wishlist.user
    @title = wishlist.name
    @show_user_favicon = true

    wishlist_presenter = WishlistPresenter.new(wishlist:)
    props = wishlist_presenter.public_props(request:, pundit_user:, recommended_by: params[:recommended_by])

    layout_param = params[:layout]
    if layout_param == Product::Layout::PROFILE
      props[:creator_profile] = ProfilePresenter.new(pundit_user:, seller: wishlist.user).creator_profile
    elsif layout_param == Product::Layout::DISCOVER
      props[:taxonomies_for_nav] = taxonomies_for_nav
    end

    render inertia: "Wishlists/Show", props: props.merge(layout: layout_param)
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
