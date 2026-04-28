# frozen_string_literal: true

class Api::Internal::Admin::PurchasesController < Api::Internal::Admin::BaseController
  MAX_SEARCH_RESULTS = 25
  VALID_PURCHASE_STATUSES = %w[successful failed not_charged chargeback refunded].freeze

  def show
    return render json: { success: false, message: "Purchase not found" }, status: :not_found unless params[:id].to_s.match?(/\A\d+\z/)

    purchase = Purchase.find_by_external_id_numeric(params[:id].to_i)
    return render json: { success: false, message: "Purchase not found" }, status: :not_found if purchase.blank?

    render json: { success: true, purchase: serialize_purchase(purchase) }
  end

  def search
    search_params = purchase_search_params

    if search_modifier_without_query?(search_params)
      return render json: { success: false, message: "query is required when product_title_query or purchase_status is provided." }, status: :bad_request
    end

    return render json: { success: false, message: "At least one search parameter is required." }, status: :bad_request if search_params.blank?

    if invalid_purchase_status?(search_params[:purchase_status])
      return render json: { success: false, message: "purchase_status must be one of: #{VALID_PURCHASE_STATUSES.to_sentence(last_word_connector: ', or ')}." }, status: :bad_request
    end

    limit = purchase_search_limit
    purchases = AdminSearchService.new.search_purchases(**search_params, limit: limit.next).includes(:link, :seller, :refunds).to_a
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
      }.transform_values { _1.is_a?(String) ? _1.strip : _1 }.compact_blank
    end

    def search_modifier_without_query?(search_params)
      search_params[:query].blank? && (search_params[:product_title_query].present? || search_params[:purchase_status].present?)
    end

    def invalid_purchase_status?(purchase_status)
      purchase_status.present? && VALID_PURCHASE_STATUSES.exclude?(purchase_status)
    end

    def purchase_search_limit
      requested_limit = params[:limit].to_i
      return MAX_SEARCH_RESULTS if requested_limit <= 0

      [requested_limit, MAX_SEARCH_RESULTS].min
    end
end
