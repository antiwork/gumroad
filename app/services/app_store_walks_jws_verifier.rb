# frozen_string_literal: true

# Verifies Apple-signed StoreKit 2 transaction JWS for the Gumroad Walks
# ProSub subscription. Returns an immutable Result; never raises on bad input.
class AppStoreWalksJwsVerifier
  PRODUCT_ID = "ProSub"
  BUNDLE_ID = "com.gumroad.walks"
  ENVIRONMENT = Rails.env.production? ? "Production" : "Sandbox"
  APPLE_ROOT_CA_PATH = Rails.root.join("config", "certs", "AppleRootCA-G3.pem")

  Result = Struct.new(:valid?, :expires_at, :product_id, :original_transaction_id, :error, keyword_init: true)

  class << self
    def verify(jws_string)
      return Result.new(valid?: false, error: "missing") if jws_string.blank?

      parts = jws_string.split(".")
      return Result.new(valid?: false, error: "malformed") if parts.length != 3

      header = JSON.parse(Base64.urlsafe_decode64(pad(parts[0])))
      x5c = header["x5c"]
      return Result.new(valid?: false, error: "no_x5c") unless x5c.is_a?(Array) && x5c.length >= 2

      certs = x5c.map { |b64| OpenSSL::X509::Certificate.new(Base64.decode64(b64)) }
      leaf = certs.first
      return Result.new(valid?: false, error: "chain") unless chain_valid?(leaf, certs[1..])

      payload, _alg = JWT.decode(jws_string, leaf.public_key, true, algorithm: "ES256")
      expires_at = ms_to_time(payload["expiresDate"])
      revoked = payload["revocationDate"].present?
      product_id = payload["productId"]
      bundle_id = payload["bundleId"]
      environment = payload["environment"]

      ok = !revoked &&
        expires_at && expires_at > Time.current &&
        product_id == PRODUCT_ID &&
        bundle_id == BUNDLE_ID &&
        environment == ENVIRONMENT

      Result.new(
        valid?: ok,
        expires_at: expires_at,
        product_id: product_id,
        original_transaction_id: payload["originalTransactionId"],
        error: ok ? nil : "not_entitled",
      )
    rescue JWT::DecodeError, JSON::ParserError, OpenSSL::X509::CertificateError, ArgumentError => e
      Result.new(valid?: false, error: e.class.name)
    end

    private
      def chain_valid?(leaf, intermediates)
        store = OpenSSL::X509::Store.new
        store.add_cert(apple_root_ca)
        store.verify(leaf, intermediates)
      end

      def apple_root_ca
        @apple_root_ca ||= OpenSSL::X509::Certificate.new(File.read(APPLE_ROOT_CA_PATH))
      end

      def ms_to_time(ms)
        return nil unless ms.is_a?(Numeric)
        Time.at(ms / 1000.0)
      end

      def pad(b64)
        b64 + ("=" * (-b64.size % 4))
      end
  end
end
