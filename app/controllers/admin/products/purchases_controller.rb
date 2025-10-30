# frozen_string_literal: true

class Admin::Products::PurchasesController < Admin::Products::BaseController
  include Pagy::Backend

  def index
    pagination, purchases = pagy_countless(
      @product.sales.for_admin_listing.includes(:subscription, :price, :refunds),
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
