# frozen_string_literal: true

# Shared "may this caller use the walks endpoints?" check for the two paid
# walks endpoints (realtime_tokens, synthesis).
#
# Two entitlement paths, evaluated in order:
#
# 1. Active Gumroad Walks subscription. Caller sends an Apple-signed StoreKit
#    `X-Apple-Transaction-JWS` header for `ProSub` and we verify it offline
#    against Apple Root CA G3 via `AppStoreWalksJwsVerifier`.
#
# 2. One free walk per device. Every request carries an App Attest assertion
#    (keyId / assertion / challenge headers) that binds the request body to a
#    Secure-Enclave key Apple attested for us during onboarding. The verifier
#    enforces signature, challenge freshness, and counter advance.
#    `realtime_tokens` *consumes* the free-trial slot (one-shot per keyId);
#    `synthesis` consumes one of up to `WalksFreeTrial::MAX_SYNTHESIS_ATTEMPTS`
#    retry slots tied to that same free walk, so transient Anthropic failures
#    can be retried without the slot becoming a permanent "may call Claude"
#    flag.
#
# Anything else → 402. The 402 body carries a `reason` symbol so the iOS app
# can distinguish "you need to attest first" from "you need to subscribe."
module WalksEntitlement
  extend ActiveSupport::Concern

  private
    def require_walks_entitlement(consumes_free_trial:)
      @walks_app_attest_key = verify_app_attest_assertion
      unless @walks_app_attest_key
        return render_payment_required("invalid_assertion")
      end

      return if valid_jws?

      if consumes_free_trial
        return if WalksFreeTrial.consume(walks_app_attest_key: @walks_app_attest_key)
      else
        return if @walks_app_attest_key.walks_free_trial&.consume_synthesis_attempt
      end

      render_payment_required("subscription_required")
    end

    def verify_app_attest_assertion
      if dev_bypass?
        return WalksAppAttestKey.find_or_create_by!(key_id: "dev-bypass") do |k|
          k.public_key = "\x00".b
          k.environment = "development"
          k.attested_at = Time.current
        end
      end

      key_id    = request.headers["X-App-Attest-KeyId"].to_s.presence
      assertion = request.headers["X-App-Attest-Assertion"].to_s.presence
      challenge = request.headers["X-App-Attest-Challenge"].to_s.presence
      if key_id.nil? || assertion.nil? || challenge.nil?
        Rails.logger.warn("WalksAppAttest assertion rejected: missing_headers")
        return nil
      end

      result = WalksAppAttestVerifier.assert(
        key_id: key_id,
        assertion_b64: assertion,
        challenge: challenge,
        request_body: request.raw_post,
      )
      return result.key if result.valid?

      # The verifier's specific failure symbol (e.g. bad_signature vs
      # invalid_challenge) is otherwise discarded here — log it so a 402 on
      # the walks endpoints can be diagnosed without a client-side capture.
      # Mirrors the attestations controller, which already logs its reason.
      Rails.logger.warn("WalksAppAttest assertion rejected: #{result.error}")
      nil
    end

    def valid_jws?
      jws = request.headers["X-Apple-Transaction-JWS"].to_s.presence
      jws.present? && AppStoreWalksJwsVerifier.verify(jws).valid?
    end

    def render_payment_required(reason)
      render json: { error: "Active Gumroad Walks subscription required.", reason: reason }, status: :payment_required
    end

    # Simulator-only escape hatch. Real iPhones must use App Attest. Guarded
    # twice: never accept in production, and require a server-configured shared
    # secret so a CI/staging deploy can't be probed from the public internet.
    def dev_bypass?
      return false if Rails.env.production?
      expected = GlobalConfig.get("WALKS_DEV_BYPASS_TOKEN").to_s
      return false if expected.blank?
      ActiveSupport::SecurityUtils.secure_compare(
        request.headers["X-Walks-Dev-Bypass"].to_s, expected
      )
    end
end
