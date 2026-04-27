# frozen_string_literal: true

class Api::Internal::Admin::BaseController < Api::Internal::BaseController
  skip_before_action :verify_authenticity_token
  before_action :verify_authorization_header!
  before_action :authorize_admin_token!

  private
    def authorize_admin_token!
      token = request.authorization.split(" ").last
      expected_token = GlobalConfig.get("INTERNAL_ADMIN_API_TOKEN").to_s

      unless expected_token.present? && token.present? && ActiveSupport::SecurityUtils.secure_compare(token, expected_token)
        render json: { success: false, message: "authorization is invalid" }, status: :unauthorized
      end
    end

    def verify_authorization_header!
      render json: { success: false, message: "unauthenticated" }, status: :unauthorized if request.authorization.nil?
    end

    def serialize_purchase(purchase)
      {
        id: purchase.external_id_numeric.to_s,
        email: purchase.email,
        seller_email: purchase.seller_email,
        product_name: purchase.link&.name,
        link_name: purchase.link_name,
        product_id: purchase.link&.external_id_numeric&.to_s,
        formatted_total_price: purchase.formatted_total_price,
        price_cents: purchase.price_cents,
        purchase_state: purchase.purchase_state,
        refund_status: refund_status(purchase),
        created_at: purchase.created_at.as_json,
        receipt_url: receipt_purchase_url(purchase.external_id, host: UrlService.domain_with_protocol, email: purchase.email)
      }.tap do |payload|
        payload[:refund_amount] = purchase.amount_refunded_cents if purchase.amount_refunded_cents.positive?
        payload[:refund_date] = purchase.refunds.order(:created_at).last&.created_at&.as_json if payload[:refund_status].present?
      end
    end

    def serialize_payout(payment)
      {
        external_id: payment.external_id,
        amount_cents: payment.amount_cents,
        currency: payment.currency,
        state: payment.state,
        created_at: payment.created_at.as_json,
        processor: payment.processor,
        bank_account_visual: payment.bank_account&.account_number_visual,
        paypal_email: payment.payment_address
      }
    end

    def refund_status(purchase)
      if purchase.refunded?
        "refunded"
      elsif purchase.stripe_partially_refunded
        "partially_refunded"
      end
    end
end
