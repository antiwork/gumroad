# frozen_string_literal: true

module LogrageHelper
  MOBILE_API_PATH_PREFIXES = %w[/mobile/ /v2/ /internal/].freeze

  def append_info_to_payload(payload)
    super

    payload[:remote_ip] = request.remote_ip
    payload[:uuid]      = request.uuid
    payload[:headers]   = {
      "CF-RAY" => request.headers["HTTP_CF_RAY"],
      "X-Amzn-Trace-Id" => request.headers["HTTP_X_AMZN_TRACE_ID"],
      "X-Revision" => REVISION
    }

    if MOBILE_API_PATH_PREFIXES.any? { |prefix| request.path.start_with?(prefix) }
      payload[:has_auth] = request.headers["Authorization"].present?
      payload[:has_mobile_token] = request.params["mobile_token"].present?
      if defined?(doorkeeper_token) && doorkeeper_token
        payload[:auth_user_id] = doorkeeper_token.resource_owner_id
        payload[:auth_token_id] = doorkeeper_token.id
      end
    end
  end
end
