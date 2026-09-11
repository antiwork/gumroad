# frozen_string_literal: true

class TiktokWebhook
  # TikTok signs `t=<unix>,s=<hex>` over "#{timestamp}.#{raw_body}".
  # The replay window is undocumented; retries should carry a fresh timestamp.
  MAX_TIMESTAMP_AGE = 5.minutes

  def initialize(client_secret = TIKTOK_CLIENT_SECRET)
    @client_secret = client_secret
  end

  def parse(raw_body, signature)
    return if raw_body.blank? || signature.blank? || @client_secret.blank?

    timestamp, provided = timestamp_and_digest(signature)
    return if timestamp.blank? || provided.blank? || !timestamp.match?(/\A\d+\z/)

    expected = OpenSSL::HMAC.hexdigest("SHA256", @client_secret, "#{timestamp}.#{raw_body}")
    return unless provided.bytesize == expected.bytesize
    return unless ActiveSupport::SecurityUtils.secure_compare(provided, expected)
    return unless timestamp_fresh?(timestamp)

    payload = JSON.parse(raw_body)
    return unless payload.is_a?(Hash)

    payload
  rescue JSON::ParserError
    nil
  end

  def open_id(payload)
    return if payload.blank?

    # TikTok documents user_openid. content can be a JSON string on the wire,
    # so dig("content", ...) would TypeError; do not fall back to undocumented shapes.
    payload["user_openid"].presence
  end

  private
    def timestamp_and_digest(signature)
      parts = signature.to_s.split(",").each_with_object({}) do |pair, acc|
        key, value = pair.split("=", 2)
        acc[key] = value if key.present? && value.present?
      end
      [parts["t"], parts["s"]]
    end

    def timestamp_fresh?(timestamp)
      (Time.current.to_i - Integer(timestamp, 10)).abs <= MAX_TIMESTAMP_AGE.to_i
    end
end
