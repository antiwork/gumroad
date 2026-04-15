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

  def mass_refund_for_fraud
    external_ids = params[:purchase_ids].reject(&:blank?).uniq

    if external_ids.empty?
      render json: { success: false, message: "Select at least one purchase." }, status: :unprocessable_entity
      return
    end

    purchases_relation = @product.sales.by_external_ids(external_ids)
    found_external_ids = purchases_relation.map(&:external_id)
    missing_external_ids = external_ids - found_external_ids

    if missing_external_ids.any?
      render json: { success: false, message: "Some purchases are invalid for this product." }, status: :unprocessable_entity
      return
    end

    MassRefundForFraudJob.perform_async(@product.id, external_ids, current_user.id)

    render json: {
      success: true,
      message: "Processing #{external_ids.size} fraud refunds..."
    }
  end
end
