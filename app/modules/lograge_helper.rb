# frozen_string_literal: true

module LogrageHelper
  def append_info_to_payload(payload)
    super

    payload[:remote_ip] = request.remote_ip
    payload[:uuid]      = request.uuid
    payload[:headers]   = {
      "CF-RAY" => request.headers["HTTP_CF_RAY"],
      "X-Amzn-Trace-Id" => request.headers["HTTP_X_AMZN_TRACE_ID"],
      "X-Revision" => REVISION
    }
  end
end
