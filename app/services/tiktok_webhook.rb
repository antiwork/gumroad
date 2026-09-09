# frozen_string_literal: true

class TiktokWebhook
  def initialize(client_secret = TIKTOK_CLIENT_SECRET)
    @client_secret = client_secret
  end

  def parse(raw_body, signature)
    return if raw_body.blank? || signature.blank? || @client_secret.blank?

    expected = OpenSSL::HMAC.hexdigest("SHA256", @client_secret, raw_body)
    provided = signature.to_s.delete_prefix("sha256=")
    return unless provided.bytesize == expected.bytesize
    return unless ActiveSupport::SecurityUtils.secure_compare(provided, expected)

    payload = JSON.parse(raw_body)
    return unless payload.is_a?(Hash)

    payload
  rescue JSON::ParserError
    nil
  end

  def open_id(payload)
    return if payload.blank?

    payload["user_openid"].presence || payload.dig("content", "open_id").presence || payload.dig("user", "open_id").presence
  end
end
