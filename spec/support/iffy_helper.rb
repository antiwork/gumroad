# frozen_string_literal: true

module IffySpecHelper
  def set_headers(json: nil)
    hmac = OpenSSL::HMAC.hexdigest("sha256", GlobalConfig.get("IFFY_WEBHOOK_SECRET"), json.to_json)
    request.headers["X-Signature"] = hmac
    request.headers["Content-Type"] = "application/json"
  end
end
