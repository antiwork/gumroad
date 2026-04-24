# frozen_string_literal: true

class Api::Internal::Helper::PurchasesController < Api::Internal::Helper::BaseController
  before_action :fetch_last_purchase, only: [:refund_last_purchase, :resend_last_receipt]

  def refund_last_purchase
    if @purchase.present? && @purchase.refund_and_save!(GUMROAD_ADMIN_ID)
      render json: { success: true, message: "Successfully refunded purchase number #{@purchase.external_id_numeric}" }
    else
      render json: { success: false, message: @purchase.present? ? @purchase.errors.full_messages.to_sentence : "Purchase not found" }, status: :unprocessable_entity
    end
  end

  def resend_last_receipt
    @purchase.resend_receipt
    render json: { success: true, message: "Successfully resent receipt for purchase number #{@purchase.external_id_numeric}" }
  end

  def resend_all_receipts
    purchases = Purchase.where(email: params[:email]).successful
    return render json: { success: false, message: "No purchases found for email: #{params[:email]}" }, status: :not_found if purchases.empty?

    CustomerMailer.grouped_receipt(purchases.ids).deliver_later(queue: "critical")
    render json: {
      success: true,
      message: "Successfully resent all receipts to #{params[:email]}",
      count: purchases.count
    }
  end

  def search
    search_params = {
      query: params[:query],
      email: params[:email],
      creator_email: params[:creator_email],
      license_key: params[:license_key],
      transaction_date: params[:purchase_date],
      price: params[:charge_amount].present? ? params[:charge_amount].to_f : nil,
      card_type: params[:card_type],
      last_4: params[:card_last4],
    }
    return render json: { success: false, message: "At least one of the parameters is required." }, status: :bad_request if search_params.compact.blank?

    purchase = AdminSearchService.new.search_purchases(**search_params, limit: 1).first
    return render json: { success: false, message: "Purchase not found" }, status: :not_found if purchase.nil?

    purchase_json = purchase.slice(:email, :link_name, :price_cents, :purchase_state, :created_at)
    purchase_json[:id] = purchase.external_id_numeric
    purchase_json[:seller_email] = purchase.seller_email
    purchase_json[:receipt_url] = receipt_purchase_url(purchase.external_id, host: UrlService.domain_with_protocol, email: purchase.email)

    if purchase.refunded?
      purchase_json[:refund_status] = "refunded"
    elsif purchase.stripe_partially_refunded
      purchase_json[:refund_status] = "partially_refunded"
    else
      purchase_json[:refund_status] = nil
    end

    if purchase.amount_refunded_cents > 0
      purchase_json[:refund_amount] = purchase.amount_refunded_cents
    end

    if purchase_json[:refund_status]
      purchase_json[:refund_date] = purchase.refunds.order(:created_at).last&.created_at
    end

    render json: { success: true, message: "Purchase found", purchase: purchase_json }
  rescue AdminSearchService::InvalidDateError
    render json: { success: false, message: "purchase_date must use YYYY-MM-DD format." }, status: :bad_request
  end

  def resend_receipt_by_number
    purchase = Purchase.find_by_external_id_numeric(params[:purchase_number].to_i)
    return e404_json unless purchase.present?

    purchase.resend_receipt
    render json: { success: true, message: "Successfully resent receipt for purchase number #{purchase.external_id_numeric} to #{purchase.email}" }
  end

  def reassign_purchases
    from_email = params[:from]
    to_email = params[:to]

    return render json: { success: false, message: "Both 'from' and 'to' email addresses are required" }, status: :bad_request unless from_email.present? && to_email.present?

    purchases = Purchase.where(email: from_email)
    return render json: { success: false, message: "No purchases found for email: #{from_email}" }, status: :not_found if purchases.empty?

    target_user = User.find_by(email: to_email)
    reassigned_purchase_ids = []

    purchases.each do |purchase|
      purchase.email = to_email

      if purchase.subscription.present? && !purchase.is_original_subscription_purchase? && !purchases.include?(purchase.original_purchase)
        purchase.original_purchase.update(email: to_email)
        reassigned_purchase_ids << purchase.original_purchase.id if purchase.original_purchase.saved_changes?
      end

      purchase.purchaser_id = target_user&.id

      if purchase.is_original_subscription_purchase? && purchase.subscription.present?
        if target_user
          purchase.subscription.user = target_user
          purchase.subscription.save
        else
          purchase.subscription.user = nil
          purchase.subscription.save
        end
      end

      if purchase.save
        reassigned_purchase_ids << purchase.id
      end
    end

    if reassigned_purchase_ids.any?
      CustomerMailer.grouped_receipt(reassigned_purchase_ids).deliver_later(queue: "critical")
    end

    render json: {
      success: true,
      message: "Successfully reassigned #{reassigned_purchase_ids.size} purchases from #{from_email} to #{to_email}. Receipt sent to #{to_email}.",
      count: reassigned_purchase_ids.size,
      reassigned_purchase_ids: reassigned_purchase_ids
    }
  end

  def auto_refund_purchase
    purchase_id = params[:purchase_id].to_i
    email = params[:email]

    purchase = Purchase.find_by_external_id_numeric(purchase_id)

    unless purchase && purchase.email.downcase == email.downcase
      return render json: { success: false, message: "Purchase not found or email doesn't match" }, status: :not_found
    end

    unless purchase.within_refund_policy_timeframe?
      return render json: { success: false, message: "Purchase is outside of the refund policy timeframe" }, status: :unprocessable_entity
    end

    if purchase.purchase_refund_policy&.fine_print.present?
      return render json: { success: false, message: "This product has specific refund conditions that require seller review" }, status: :unprocessable_entity
    end

    if purchase.refund_and_save!(GUMROAD_ADMIN_ID)
      render json: { success: true, message: "Successfully refunded purchase number #{purchase.external_id_numeric}" }
    else
      render json: { success: false, message: "Refund failed for purchase number #{purchase.external_id_numeric}" }, status: :unprocessable_entity
    end
  end

  def refund_taxes_only
    purchase_id = params[:purchase_id]&.to_i
    email = params[:email]

    return render json: { success: false, message: "Both 'purchase_id' and 'email' parameters are required" }, status: :bad_request unless purchase_id.present? && email.present?

    purchase = Purchase.find_by_external_id_numeric(purchase_id)

    unless purchase && purchase.email.downcase == email.downcase
      return render json: { success: false, message: "Purchase not found or email doesn't match" }, status: :not_found
    end

    if purchase.refund_gumroad_taxes!(refunding_user_id: GUMROAD_ADMIN_ID, note: params[:note], business_vat_id: params[:business_vat_id])
      render json: { success: true, message: "Successfully refunded taxes for purchase number #{purchase.external_id_numeric}" }
    else
      error_message = purchase.errors.full_messages.presence&.to_sentence || "No refundable taxes available"
      render json: { success: false, message: error_message }, status: :unprocessable_entity
    end
  end

  private
    def fetch_last_purchase
      @purchase = Purchase.where(email: params[:email]).order(created_at: :desc).first
      e404_json unless @purchase
    end
end
