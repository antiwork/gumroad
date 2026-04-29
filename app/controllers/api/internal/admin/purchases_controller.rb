# frozen_string_literal: true

class Api::Internal::Admin::PurchasesController < Api::Internal::Admin::BaseController
  include CurrencyHelper

  MAX_SEARCH_RESULTS = 25
  VALID_PURCHASE_STATUSES = %w[successful failed not_charged chargeback refunded].freeze

  def show
    purchase = fetch_purchase
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

  def refund
    buyer_email = params[:email].to_s.strip.downcase
    return render json: { success: false, message: "email is required" }, status: :bad_request if buyer_email.blank?

    purchase = fetch_purchase
    if purchase.blank? || purchase.email.to_s.downcase != buyer_email
      return render json: { success: false, message: "Purchase not found or email doesn't match" }, status: :not_found
    end

    if purchase.stripe_refunded
      return render json: { success: false, message: "Purchase has already been fully refunded" }, status: :unprocessable_entity
    end

    if purchase.stripe_transaction_id.blank? || purchase.amount_refundable_cents <= 0
      return render json: { success: false, message: "Purchase has no charge to refund" }, status: :unprocessable_entity
    end

    force = ActiveModel::Type::Boolean.new.cast(params[:force])

    unless force
      unless purchase.within_refund_policy_timeframe?
        return render json: { success: false, message: "Purchase is outside of the refund policy timeframe" }, status: :unprocessable_entity
      end

      if purchase.purchase_refund_policy&.fine_print.present?
        return render json: { success: false, message: "This product has specific refund conditions that require seller review" }, status: :unprocessable_entity
      end
    end

    amount = nil
    if params[:amount_cents].present?
      raw_amount_cents = params[:amount_cents]
      unless raw_amount_cents.is_a?(Integer) || raw_amount_cents.to_s.match?(/\A\d+\z/)
        return render json: { success: false, message: "amount_cents must be a positive integer" }, status: :unprocessable_entity
      end
      amount_cents = raw_amount_cents.to_i
      if amount_cents <= 0
        return render json: { success: false, message: "amount_cents must be a positive integer" }, status: :unprocessable_entity
      end
      amount = amount_cents / unit_scaling_factor(purchase.displayed_price_currency_type).to_f
    end

    unless purchase.refund!(refunding_user_id: GUMROAD_ADMIN_ID, amount:)
      message = purchase.errors.full_messages.presence&.to_sentence || "Refund failed for purchase number #{purchase.external_id_numeric}"
      return render json: { success: false, message: }, status: :unprocessable_entity
    end

    subscription_cancelled = false
    subscription_cancel_error = nil
    subscription = purchase.subscription
    if ActiveModel::Type::Boolean.new.cast(params[:cancel_subscription]) &&
        subscription.present? &&
        subscription.cancelled_at.blank? &&
        !subscription.deactivated?
      begin
        subscription.cancel!(by_seller: true, by_admin: true)
        subscription_cancelled = subscription.cancelled_at.present?
      rescue => e
        subscription_cancel_error = e.message
        Rails.logger.error("[admin/refund] subscription cancel failed for purchase #{purchase.external_id_numeric}: #{e.class}: #{e.message}")
      end
    end

    render json: {
      success: true,
      message: "Successfully refunded purchase number #{purchase.external_id_numeric}",
      purchase: serialize_purchase(purchase),
      subscription_cancelled:,
      subscription_cancel_error:
    }.compact
  end

  private
    def fetch_purchase
      return nil unless params[:id].to_s.match?(/\A\d+\z/)
      Purchase.find_by_external_id_numeric(params[:id].to_i)
    end

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
