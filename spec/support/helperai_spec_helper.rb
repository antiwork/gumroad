# frozen_string_literal: true

module HelperAISpecHelper
  def set_headers(params: nil, json: nil)
    hmac = Helper::Client.new.create_hmac_digest(params:, json:)
    hmac_base64 = Base64.encode64(hmac)
    request.headers["Authorization"] = "Bearer #{hmac_base64}"
    request.headers["Content-Type"] = "application/json"
  end
end
