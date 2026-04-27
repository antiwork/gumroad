# frozen_string_literal: true

class Api::Internal::Admin::PurchasesController < Api::Internal::Admin::BaseController
  include CurrencyHelper

  def show
    purchase = fetch_purchase
    return render json: { success: false, message: "Purchase not found" }, status: :not_found if purchase.blank?

    render json: { success: true, purchase: serialize_purchase(purchase) }
  end

  def refund
    return render json: { success: false, message: "email is required" }, status: :bad_request if params[:email].blank?

    purchase = fetch_purchase
    if purchase.blank? || purchase.email.to_s.downcase != params[:email].to_s.downcase
      return render json: { success: false, message: "Purchase not found or email doesn't match" }, status: :not_found
    end

    if purchase.stripe_refunded
      return render json: { success: false, message: "Purchase has already been fully refunded" }, status: :unprocessable_entity
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
      amount_cents = params[:amount_cents].to_i
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
    if ActiveModel::Type::Boolean.new.cast(params[:cancel_subscription]) &&
        purchase.subscription.present? &&
        !purchase.subscription.deactivated?
      begin
        purchase.subscription.cancel!(by_seller: false, by_admin: true)
        subscription_cancelled = true
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
end
