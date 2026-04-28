# frozen_string_literal: true

class Api::Internal::Admin::PurchasesController < Api::Internal::Admin::BaseController
  MAX_SEARCH_RESULTS = 25

  def show
    return render json: { success: false, message: "Purchase not found" }, status: :not_found unless params[:id].to_s.match?(/\A\d+\z/)

    purchase = Purchase.find_by_external_id_numeric(params[:id].to_i)
    return render json: { success: false, message: "Purchase not found" }, status: :not_found if purchase.blank?

    render json: { success: true, purchase: serialize_purchase(purchase) }
  end

  def search
    if search_modifier_without_query?
      return render json: { success: false, message: "query is required when product_title_query or purchase_status is provided." }, status: :bad_request
    end

    search_params = purchase_search_params
    return render json: { success: false, message: "At least one search parameter is required." }, status: :bad_request if search_params.blank?

    limit = purchase_search_limit
    purchases = AdminSearchService.new.search_purchases(**search_params, limit: limit.next).to_a
    has_more = purchases.length > limit

    render json: {
      success: true,
      purchases: purchases.first(limit).map { serialize_purchase(_1) },
      count: [purchases.length, limit].min,
      limit:,
      has_more:
    }
  rescue AdminSearchService::InvalidDateError
    render json: { success: false, message: "purchase_date must use YYYY-MM-DD format." }, status: :bad_request
  end

  private
    def purchase_search_params
      {
        query: params[:query],
        email: params[:email],
        product_title_query: params[:product_title_query],
        purchase_status: params[:purchase_status],
        creator_email: params[:creator_email],
        license_key: params[:license_key],
        transaction_date: params[:purchase_date],
        last_4: params[:card_last4],
        card_type: params[:card_type],
        price: params[:charge_amount],
        expiry_date: params[:expiry_date],
      }.compact_blank
    end

    def search_modifier_without_query?
      params[:query].blank? && (params[:product_title_query].present? || params[:purchase_status].present?)
    end

    def purchase_search_limit
      requested_limit = params[:limit].to_i
      return MAX_SEARCH_RESULTS if requested_limit <= 0

      [requested_limit, MAX_SEARCH_RESULTS].min
    end
end
