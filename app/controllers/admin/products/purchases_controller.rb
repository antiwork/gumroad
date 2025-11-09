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
    purchase_ids = params[:purchase_ids]

    if purchase_ids.blank?
      return render json: { success: false, message: "No purchases selected" }, status: :unprocessable_entity
    end

    refunded_count = 0
    blocked_count = 0

    Purchase.where(id: purchase_ids).find_each do |purchase|
      if purchase.successful? && !purchase.stripe_refunded?
        RefundPurchaseWorker.perform_async(purchase.id, current_user.id, Refund::FRAUD)
        refunded_count += 1
      elsif purchase.failed?
        purchase.block_buyer!(blocking_user_id: current_user.id)
        blocked_count += 1
      end
    end

    message = []
    message << "#{refunded_count} purchase#{'s' if refunded_count != 1} queued for refund" if refunded_count > 0
    message << "#{blocked_count} buyer#{'s' if blocked_count != 1} blocked" if blocked_count > 0

    render json: {
      success: true,
      message: message.join(" and "),
      refunded_count:,
      blocked_count:
    }
  end
end
