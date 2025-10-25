# frozen_string_literal: true

class Admin::Users::Products::PurchasesController < Admin::Users::Products::BaseController
  include Pagy::Backend

  def index
    pagy, purchases = pagy_countless(
      @product.sales.for_affiliate_user(@user).for_admin_listing.includes(:subscription, :price, :refunds),
      limit: params[:per_page],
      page: params[:page]
    )

    render json: {
      purchases: purchases.as_json(admin_review: true),
      pagination: pagy
    }
  end
end
