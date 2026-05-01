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

  def resend_receipt
    purchase = fetch_purchase
    return render json: { success: false, message: "Purchase not found" }, status: :not_found if purchase.blank?

    record_admin_write(action: "purchases.resend_receipt", target: purchase) do
      purchase.resend_receipt
      render json: {
        success: true,
        message: "Successfully resent receipt for purchase number #{purchase.external_id_numeric} to #{purchase.email}"
      }
    end
  end

  def resend_all_receipts
    email = params[:email].to_s.strip
    return render json: { success: false, message: "email is required" }, status: :bad_request if email.blank?

    purchases = Purchase.where(email: email).successful
    return render json: { success: false, message: "No purchases found for email: #{email}" }, status: :not_found if purchases.empty?

    record_admin_write(action: "purchases.resend_all_receipts") do
      CustomerMailer.grouped_receipt(purchases.ids).deliver_later(queue: "critical")
      render json: {
        success: true,
        message: "Successfully resent all receipts to #{email}",
        count: purchases.count
      }
    end
  end

  def refund_taxes
    buyer_email = params[:email].to_s.strip.downcase
    return render json: { success: false, message: "email is required" }, status: :bad_request if buyer_email.blank?

    purchase = fetch_purchase
    if purchase.blank? || purchase.email.to_s.downcase != buyer_email
      return render json: { success: false, message: "Purchase not found or email doesn't match" }, status: :not_found
    end

    record_admin_write(action: "purchases.refund_taxes", target: purchase) do
      if purchase.refund_gumroad_taxes!(refunding_user_id: current_admin_actor_id, note: params[:note], business_vat_id: params[:business_vat_id])
        render json: {
          success: true,
          message: "Successfully refunded taxes for purchase number #{purchase.external_id_numeric}",
          purchase: serialize_purchase(purchase)
        }
      else
        message = purchase.errors.full_messages.presence&.to_sentence || "No refundable taxes available"
        render json: { success: false, message: message }, status: :unprocessable_entity
      end
    end
  end

  def reassign
    from_email = params[:from].to_s.strip.presence
    to_email = params[:to].to_s.strip.presence

    record_admin_write(action: "purchases.reassign") do
      result = Purchase::ReassignByEmailService.new(from_email:, to_email:).perform

      unless result.success?
        return render json: { success: false, message: result.error_message }, status: status_for_reason(result.reason)
      end

      render json: {
        success: true,
        message: "Successfully reassigned #{result.count} purchases from #{from_email} to #{to_email}. Receipt sent to #{to_email}.",
        count: result.count,
        reassigned_purchase_ids: result.reassigned_purchase_ids
      }
    end
  end

  def refund
    buyer_email = params[:email].to_s.strip.downcase
    return render json: { success: false, message: "email is required" }, status: :bad_request if buyer_email.blank?

    purchase = fetch_purchase
    if purchase.blank? || purchase.email.to_s.downcase != buyer_email
      return render json: { success: false, message: "Purchase not found or email doesn't match" }, status: :not_found
    end

    record_admin_write(action: "purchases.refund", target: purchase) do
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

      unless purchase.refund!(refunding_user_id: current_admin_actor_id, amount:)
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
  end

  def cancel_subscription
    purchase = fetch_purchase_with_email_match
    return unless purchase

    record_admin_write(action: "purchases.cancel_subscription", target: purchase) do
      subscription = purchase.subscription
      if subscription.blank?
        return render json: { success: false, message: "Purchase has no subscription" }, status: :unprocessable_entity
      end

      if subscription.cancelled_at.present?
        return render json: {
          success: true,
          status: "already_cancelled",
          message: "Subscription is already cancelled",
          cancelled_at: subscription.cancelled_at.as_json,
          cancelled_by_admin: subscription.cancelled_by_admin?
        }
      end

      if subscription.deactivated?
        return render json: {
          success: true,
          status: "already_inactive",
          message: "Subscription is no longer active",
          termination_reason: subscription.termination_reason,
          deactivated_at: subscription.deactivated_at&.as_json
        }
      end

      by_seller = ActiveModel::Type::Boolean.new.cast(params[:by_seller]) == true
      subscription.cancel!(by_seller: by_seller, by_admin: true)

      render json: {
        success: true,
        message: "Successfully cancelled subscription for purchase number #{purchase.external_id_numeric}",
        cancelled_at: subscription.cancelled_at&.as_json,
        cancelled_by_admin: subscription.cancelled_by_admin?,
        cancelled_by_seller: !subscription.cancelled_by_buyer?
      }
    end
  end

  def block_buyer
    purchase = fetch_purchase_with_email_match
    return unless purchase

    record_admin_write(action: "purchases.block_buyer", target: purchase) do
      if purchase.is_buyer_blocked_by_admin? && purchase.buyer_blocked?
        return render json: {
          success: true,
          status: "already_blocked",
          message: "Buyer is already blocked by admin"
        }
      end

      purchase.block_buyer!(blocking_user_id: current_admin_actor_id, comment_content: params[:comment_content].presence)

      render json: {
        success: true,
        message: "Successfully blocked buyer for purchase number #{purchase.external_id_numeric}"
      }
    end
  end

  def unblock_buyer
    purchase = fetch_purchase_with_email_match
    return unless purchase

    record_admin_write(action: "purchases.unblock_buyer", target: purchase) do
      unless purchase.buyer_blocked? || purchase.is_buyer_blocked_by_admin?
        return render json: {
          success: true,
          status: "not_blocked",
          message: "Buyer is not blocked"
        }
      end

      purchase.unblock_buyer!
      create_unblock_buyer_comments!(purchase)

      render json: {
        success: true,
        message: "Successfully unblocked buyer for purchase number #{purchase.external_id_numeric}"
      }
    end
  end

  def refund_for_fraud
    purchase = fetch_purchase_with_email_match
    return unless purchase

    record_admin_write(action: "purchases.refund_for_fraud", target: purchase) do
      if purchase.stripe_refunded
        return render json: { success: false, message: "Purchase has already been fully refunded" }, status: :unprocessable_entity
      end

      if purchase.stripe_transaction_id.blank? || purchase.amount_refundable_cents <= 0
        return render json: { success: false, message: "Purchase has no charge to refund" }, status: :unprocessable_entity
      end

      unless purchase.refund_for_fraud_and_block_buyer!(current_admin_actor_id)
        message = purchase.errors.full_messages.presence&.to_sentence || "Refund-for-fraud failed for purchase number #{purchase.external_id_numeric}"
        return render json: { success: false, message: }, status: :unprocessable_entity
      end

      render json: {
        success: true,
        message: "Successfully refunded purchase number #{purchase.external_id_numeric} for fraud and blocked the buyer",
        purchase: serialize_purchase(purchase),
        subscription_cancelled: purchase.subscription&.cancelled_at.present?
      }
    end
  end

  private
    def create_unblock_buyer_comments!(purchase)
      content = "Buyer unblocked by Admin"
      purchase.comments.create!(content:, comment_type: Comment::COMMENT_TYPE_NOTE, author_id: current_admin_actor_id)
      if purchase.purchaser.present?
        purchase.purchaser.comments.create!(content:, comment_type: Comment::COMMENT_TYPE_NOTE, author_id: current_admin_actor_id, purchase:)
      end
    end

    def fetch_purchase_with_email_match
      buyer_email = params[:email].to_s.strip.downcase
      if buyer_email.blank?
        render json: { success: false, message: "email is required" }, status: :bad_request
        return nil
      end

      purchase = fetch_purchase
      if purchase.blank? || purchase.email.to_s.downcase != buyer_email
        render json: { success: false, message: "Purchase not found or email doesn't match" }, status: :not_found
        return nil
      end

      purchase
    end

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

    def status_for_reason(reason)
      case reason
      when :missing_params then :bad_request
      when :not_found then :not_found
      when :no_changes then :unprocessable_entity
      end
    end
end
