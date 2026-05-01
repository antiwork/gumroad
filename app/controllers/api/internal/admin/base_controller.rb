# frozen_string_literal: true

class Api::Internal::Admin::BaseController < Api::Internal::BaseController
  include AdminActor
  include AfterCommitEverywhere

  ADMIN_AUDIT_REDACTED_PARAM_PATTERN = /password|secret|token|two_factor|otp|webhook_url|license_key|email/i
  ADMIN_AUDIT_ACTION_REDACTED_PARAM_KEYS = {
    "purchases.reassign" => %w[from to]
  }.freeze
  ADMIN_AUDIT_ACTIONS_ALLOWING_NULL_TARGET = %w[
    purchases.reassign
    purchases.resend_all_receipts
  ].freeze

  skip_before_action :verify_authenticity_token
  before_action :verify_authorization_header!
  before_action :authorize_admin_token!

  private
    def authorize_admin_token!
      token = bearer_token
      admin_api_token = AdminApiToken.authenticate(token)
      return render_invalid_authorization unless admin_api_token

      set_current_admin_actor!(admin_api_token.actor_user, admin_token: admin_api_token)
      admin_api_token.record_used!
    end

    def require_per_actor_token!
      return if Current.admin_token.present? && !Current.admin_token.legacy_admin_token?

      render json: { success: false, message: "per-actor admin token is required" }, status: :unauthorized
    end

    def verify_authorization_header!
      render json: { success: false, message: "unauthenticated" }, status: :unauthorized if request.authorization.nil?
    end

    def bearer_token
      authorization_header = request.authorization.to_s
      authorization_header.match(/\ABearer (.+)\z/)&.[](1)
    end

    def render_invalid_authorization
      render json: { success: false, message: "authorization is invalid" }, status: :unauthorized
    end

    def current_admin_actor_id
      Current.admin_actor.id
    end

    def record_admin_write(action:, target: nil)
      validate_admin_audit_target!(action:, target:)

      error = nil
      begin
        yield
      rescue => e
        error = e
        raise
      ensure
        write_admin_audit_log(action:, target:, error:)
      end
    end

    def validate_admin_audit_target!(action:, target:)
      return if action.present? && (target.present? || ADMIN_AUDIT_ACTIONS_ALLOWING_NULL_TARGET.include?(action))

      raise ArgumentError, "admin write audit target is required for #{action.presence || "unknown action"}"
    end

    def write_admin_audit_log(action:, target:, error:)
      return if Current.admin_actor.blank? || Current.admin_token.blank?

      attributes = {
        actor_user_id: Current.admin_actor.id,
        admin_api_token_id: Current.admin_token.id,
        action:,
        target_type: admin_audit_target_type(target),
        target_id: target&.id,
        target_external_id: admin_audit_target_external_id(target),
        route: request.path,
        http_method: request.request_method,
        params_snapshot: admin_audit_params_snapshot(action),
        request_id: request.request_id,
        response_status: error.present? ? Rack::Utils.status_code(:internal_server_error) : response.status,
        error_class: error&.class&.name,
        created_at: Time.current
      }

      after_commit do
        AdminApiAuditLog.create!(attributes)
      rescue => e
        handle_admin_audit_log_failure(e, attributes)
      end
    end

    def admin_audit_target_type(target)
      target&.class&.base_class&.name
    end

    def admin_audit_target_external_id(target)
      return if target.blank?
      return target.external_id.to_s if target.respond_to?(:external_id) && target.external_id.present?

      target.external_id_numeric.to_s if target.respond_to?(:external_id_numeric) && target.external_id_numeric.present?
    end

    def handle_admin_audit_log_failure(error, attributes)
      Rails.logger.error("Failed to record admin audit log for #{attributes[:action]}: #{error.class.name}: #{error.message}")
      ErrorNotifier.notify(error) do |report|
        report.add_metadata(:admin_audit_log, attributes.except(:params_snapshot))
      end
    end

    def admin_audit_params_snapshot(action)
      redacted_admin_audit_value(params.to_unsafe_h.except("controller", "action", "format"), action:)
    end

    def redacted_admin_audit_value(value, key: nil, action:)
      return "[REDACTED]" if admin_audit_redacted_param_key?(key, action:)

      case value
      when ActionController::Parameters
        redacted_admin_audit_value(value.to_unsafe_h, key:, action:)
      when Hash
        value.to_h.each_with_object({}) do |(nested_key, nested_value), redacted|
          redacted[nested_key] = redacted_admin_audit_value(nested_value, key: nested_key, action:)
        end
      when Array
        value.map { redacted_admin_audit_value(_1, key:, action:) }
      else
        value
      end
    end

    def admin_audit_redacted_param_key?(key, action:)
      key.to_s.match?(ADMIN_AUDIT_REDACTED_PARAM_PATTERN) ||
        ADMIN_AUDIT_ACTION_REDACTED_PARAM_KEYS.fetch(action, []).include?(key.to_s)
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
        currency_type: purchase.displayed_price_currency_type.to_s,
        amount_refundable_cents_in_currency: amount_refundable_cents_in_currency(purchase),
        purchase_state: purchase.purchase_state,
        refund_status: refund_status(purchase),
        created_at: purchase.created_at.as_json,
        receipt_url: receipt_purchase_url(purchase.external_id, host: UrlService.domain_with_protocol, email: purchase.email)
      }.tap do |payload|
        refund_amount = refund_amount_cents(purchase)
        payload[:refund_amount] = refund_amount if refund_amount.positive?
        payload[:refund_date] = latest_refund(purchase)&.created_at&.as_json if payload[:refund_status].present?
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

    def refund_amount_cents(purchase)
      return purchase.refunds.sum(&:amount_cents) if purchase.association(:refunds).loaded?

      purchase.amount_refunded_cents
    end

    def amount_refundable_cents_in_currency(purchase)
      return 0 unless purchase.charge_processor_id.in?(ChargeProcessor.charge_processor_ids)
      refundable_usd_cents = purchase.price_cents - refund_amount_cents(purchase)
      purchase.usd_cents_to_currency(purchase.link.price_currency_type, refundable_usd_cents, purchase.rate_converted_to_usd)
    end

    def latest_refund(purchase)
      return purchase.refunds.max_by(&:created_at) if purchase.association(:refunds).loaded?

      purchase.refunds.order(:created_at).last
    end
end
