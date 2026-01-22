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

    wishlist = current_seller.wishlists.new(params.require(:wishlist).permit(:name))

    respond_to do |format|
      if wishlist.save
        format.html { redirect_to wishlists_path, notice: "Wishlist created!", status: :see_other }
        format.json { render json: { wishlist: WishlistPresenter.new(wishlist:).listing_props }, status: :created }
      else
        format.html { redirect_to wishlists_path, inertia: { errors: { base: wishlist.errors.full_messages } }, status: :see_other }
        format.json { render json: { error: wishlist.errors.full_messages.first }, status: :unprocessable_entity }
      end
    end
  end

  def show
    wishlist = user_by_domain(request.host).wishlists.alive.find_by_url_slug(params[:id])
    e404 if wishlist.blank?

    @user = wishlist.user
    @title = wishlist.name
    @show_user_favicon = true

    layout = params[:layout]
    props = WishlistPresenter.new(wishlist:).public_props(
      request:,
      pundit_user:,
      recommended_by: params[:recommended_by],
      layout:,
      taxonomies_for_nav:
    )

    render inertia: "Wishlists/Show", props:
  end

  def update
    wishlist = current_seller.wishlists.alive.find_by_external_id!(params[:id])
    authorize wishlist

    if wishlist.update(params.require(:wishlist).permit(:name, :description, :discover_opted_out))
      redirect_to wishlists_path, notice: "Wishlist updated!", status: :see_other
    else
      redirect_to wishlists_path,
                  inertia: { errors: { base: wishlist.errors.full_messages } },
                  status: :see_other
    end
  end

  def destroy
    wishlist = current_seller.wishlists.alive.find_by_external_id!(params[:id])
    authorize wishlist

    wishlist.transaction do
      wishlist.mark_deleted!
      wishlist.wishlist_followers.alive.update_all(deleted_at: Time.current)
    end

    redirect_to wishlists_path, notice: "Wishlist deleted!", status: :see_other
  end
end
