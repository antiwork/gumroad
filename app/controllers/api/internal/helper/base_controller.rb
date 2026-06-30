# frozen_string_literal: true

class Api::Internal::Helper::BaseController < Api::Internal::BaseController
  include AfterCommitEverywhere

  HELPER_ADMIN_AUDIT_REDACTED_PARAM_PATTERN = /password|secret|token|two_factor|otp|webhook_url|license_key|email/i
  HELPER_ADMIN_AUDIT_ACTION_REDACTED_PARAM_KEYS = {
    "purchases.reassign" => %w[from to from_email to_email]
  }.freeze
  HELPER_ADMIN_AUDIT_ACTIONS_ALLOWING_NULL_TARGET = %w[
    purchases.reassign
  ].freeze
  HMAC_EXPIRATION = 1.minute

  skip_before_action :verify_authenticity_token
  before_action :verify_authorization_header!
  before_action :authorize_helper_token!

  private
    def authorize_hmac_signature!
      json = request.body.read.empty? ? nil : JSON.parse(request.body.read)
      query_params = json ? nil : request.query_parameters
      timestamp = json ? json.dig("timestamp") : query_params[:timestamp]

      return render json: { success: false, message: "timestamp is required" }, status: :bad_request if timestamp.blank?

      if (Time.at(timestamp.to_i) - Time.now).abs > HMAC_EXPIRATION
        return render json: { success: false, message: "bad timestamp" }, status: :unauthorized
      end

      hmac_digest = Base64.decode64(request.authorization.split(" ").last)
      expected_digest = Helper::Client.new.create_hmac_digest(params: query_params, json:)
      unless ActiveSupport::SecurityUtils.secure_compare(hmac_digest, expected_digest)
        render json: { success: false, message: "authorization is invalid" }, status: :unauthorized
      end
    end

    def authorize_helper_token!
      token = request.authorization.split(" ").last
      unless ActiveSupport::SecurityUtils.secure_compare(token, GlobalConfig.get("HELPER_TOOLS_TOKEN"))
        render json: { success: false, message: "authorization is invalid" }, status: :unauthorized
      end
    end

    def verify_authorization_header!
      render json: { success: false, message: "unauthenticated" }, status: :unauthorized if request.authorization.nil?
    end

    def record_helper_admin_write(action:, target: nil)
      validate_helper_admin_audit_target!(action:, target:)

      error = nil
      begin
        yield
      rescue => e
        error = e
        raise
      ensure
        write_helper_admin_audit_log(action:, target:, error:)
      end
    end

    def validate_helper_admin_audit_target!(action:, target:)
      return if action.present? && (target.present? || HELPER_ADMIN_AUDIT_ACTIONS_ALLOWING_NULL_TARGET.include?(action))

      raise ArgumentError, "admin write audit target is required for #{action.presence || "unknown action"}"
    end

    def write_helper_admin_audit_log(action:, target:, error:)
      admin_api_token = AdminApiToken.legacy_admin_token
      actor = admin_api_token&.actor_user
      return if actor.blank? || admin_api_token.blank?

      params_snapshot = helper_admin_audit_params_snapshot(action)
      helper_context = helper_admin_audit_context
      if helper_context.present?
        params_snapshot["helper_reassign_result"] = redacted_helper_admin_audit_value(helper_context, action:)
      end

      attributes = {
        actor_user_id: actor.id,
        admin_api_token_id: admin_api_token.id,
        action:,
        target_type: helper_admin_audit_target_type(target),
        target_id: target&.id,
        target_external_id: helper_admin_audit_target_external_id(target),
        route: request.path,
        http_method: request.request_method,
        params_snapshot:,
        request_id: request.request_id,
        response_status: error.present? ? Rack::Utils.status_code(:internal_server_error) : response.status,
        error_class: error&.class&.name,
        created_at: Time.current
      }

      after_commit do
        AdminApiAuditLog.create!(attributes)
      rescue => e
        handle_helper_admin_audit_log_failure(e, attributes)
      end
    end

    def helper_admin_audit_target_type(target)
      target&.class&.base_class&.name
    end

    def helper_admin_audit_target_external_id(target)
      return if target.blank?
      return target.external_id.to_s if target.respond_to?(:external_id) && target.external_id.present?

      target.external_id_numeric.to_s if target.respond_to?(:external_id_numeric) && target.external_id_numeric.present?
    end

    def handle_helper_admin_audit_log_failure(error, attributes)
      Rails.logger.error("Failed to record admin audit log for #{attributes[:action]}: #{error.class.name}: #{error.message}")
      ErrorNotifier.notify(error) do |report|
        report.add_metadata(:admin_audit_log, attributes.except(:params_snapshot))
      end
    end

    def helper_admin_audit_params_snapshot(action)
      redacted_helper_admin_audit_value(params.to_unsafe_h.except("controller", "action", "format"), action:)
    end

    def helper_admin_audit_context
      @helper_admin_audit_context || {}
    end

    def redacted_helper_admin_audit_value(value, key: nil, action:)
      return "[REDACTED]" if helper_admin_audit_redacted_param_key?(key, action:)

      case value
      when ActionController::Parameters
        redacted_helper_admin_audit_value(value.to_unsafe_h, key:, action:)
      when Hash
        value.to_h.each_with_object({}) do |(nested_key, nested_value), redacted|
          redacted[nested_key] = redacted_helper_admin_audit_value(nested_value, key: nested_key, action:)
        end
      when Array
        value.map { redacted_helper_admin_audit_value(_1, key:, action:) }
      else
        value
      end
    end

    def helper_admin_audit_redacted_param_key?(key, action:)
      key.to_s.match?(HELPER_ADMIN_AUDIT_REDACTED_PARAM_PATTERN) ||
        HELPER_ADMIN_AUDIT_ACTION_REDACTED_PARAM_KEYS.fetch(action, []).include?(key.to_s)
    end
end
