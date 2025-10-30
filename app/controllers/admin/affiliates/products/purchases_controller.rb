# frozen_string_literal: true

class Admin::Affiliates::Products::PurchasesController < Admin::Affiliates::Products::BaseController
  include Pagy::Backend

  def index
    scope = @product.sales.for_affiliate_user(@affiliate_user)

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
