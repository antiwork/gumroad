# frozen_string_literal: true

class Wishlists::ProductsController < ApplicationController
  before_action :authenticate_user!, except: :index
  after_action :verify_authorized, except: :index

  def index
    wishlist = Wishlist.find_by_external_id!(params[:wishlist_id])

    render json: WishlistPresenter.new(wishlist:).public_items(request:, pundit_user:, page: params[:page])
  end

  def create
    wishlist = current_seller.wishlists.find_by_external_id!(params[:wishlist_id])

    authorize wishlist
    authorize WishlistProduct

    attributes = permitted_attributes(WishlistProduct)
    product = Link.find_by_external_id!(attributes.delete(:product_id))
    option_id = attributes.delete(:option_id)
    variant = option_id.presence && product.variants_or_skus.find_by_external_id!(option_id)

    wishlist_product = wishlist.alive_wishlist_products
      .find_or_initialize_by(product:, variant:, recurrence: attributes.delete(:recurrence))

    if wishlist_product.update(attributes)
      if wishlist.wishlist_followers.alive.exists?
        SendWishlistUpdatedEmailsJob.perform_in(8.hours, wishlist.id, wishlist.wishlist_products_for_email.pluck(:id))
      end
      head :created
    else
      render json: { error: wishlist_product.errors.full_messages.first }, status: :unprocessable_entity
    end
  end

  def destroy
    wishlist_product = WishlistProduct.alive.find_by_external_id!(params[:id])

    authorize wishlist_product

    wishlist_product.mark_deleted!

    head :no_content
  end
end
