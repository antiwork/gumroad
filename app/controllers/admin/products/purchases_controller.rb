# frozen_string_literal: true

class Admin::Products::PurchasesController < Admin::Products::BaseController
  include Pagy::Backend

  def index
    scope = @product.sales
    if params[:affiliate_user_id].present?
      affiliate_user = User.find(params[:affiliate_user_id])
      scope = scope.for_affiliate_user(affiliate_user)
    end

    pagination, purchases = pagy_countless(
      scope.for_admin_listing.includes(:subscription, :price, :refunds),
      limit: params[:per_page],
      page: params[:page],
      countless_minimal: true
    )

    render json: {
      purchases: purchases.as_json(admin_review: true),
      pagination:
    }
  end
end
