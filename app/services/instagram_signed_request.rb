# frozen_string_literal: true

class InstagramSignedRequest
  ALGORITHM = "HMAC-SHA256"
  CONFIRMATION_CODE_PATTERN = /\A[0-9a-f]{48}\z/

  def initialize(app_secret = INSTAGRAM_APP_SECRET)
    @app_secret = app_secret
  end

  def parse(value)
    return if value.blank? || @app_secret.blank?

    encoded_signature, encoded_payload = value.split(".", 2)
    return if encoded_signature.blank? || encoded_payload.blank?

    signature = decode(encoded_signature)
    expected = OpenSSL::HMAC.digest("SHA256", @app_secret, encoded_payload)
    return unless signature.bytesize == expected.bytesize
    return unless ActiveSupport::SecurityUtils.secure_compare(signature, expected)

    payload = JSON.parse(decode(encoded_payload))
    return unless payload["algorithm"].to_s.upcase == ALGORITHM

    payload
  rescue ArgumentError, JSON::ParserError
    nil
  end

  def confirmation_code(user_id)
    opaque_id = OpenSSL::HMAC.hexdigest("SHA256", @app_secret, "instagram-data-deletion:#{user_id}").first(24)
    "#{opaque_id}#{confirmation_code_signature(opaque_id)}"
  end

  def valid_confirmation_code?(code)
    return false if @app_secret.blank? || !code.to_s.match?(CONFIRMATION_CODE_PATTERN)

    opaque_id = code.first(24)
    signature = code.last(24)
    ActiveSupport::SecurityUtils.secure_compare(signature, confirmation_code_signature(opaque_id))
  end

  private
    def confirmation_code_signature(opaque_id)
      OpenSSL::HMAC.hexdigest("SHA256", @app_secret, "instagram-data-deletion-status:#{opaque_id}").first(24)
    end

    def decode(value)
      Base64.urlsafe_decode64(value.ljust((value.length + 3) & ~3, "="))
    end
end
