# frozen_string_literal: true

class Api::Internal::Admin::PurchasesController < Api::Internal::Admin::BaseController
  def show
    return render json: { success: false, message: "Purchase not found" }, status: :not_found unless params[:id].to_s.match?(/\A\d+\z/)

    purchase = Purchase.find_by_external_id_numeric(params[:id].to_i)
    return render json: { success: false, message: "Purchase not found" }, status: :not_found if purchase.blank?

    render json: { success: true, purchase: serialize_purchase(purchase) }
  end
end
