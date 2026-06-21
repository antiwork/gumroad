# frozen_string_literal: true

require "base64"

module WebauthnCeremonyVerification
  extend ActiveSupport::Concern

  class VerificationError < StandardError
    attr_reader :reason

    def initialize(reason)
      @reason = reason
      super(reason)
    end
  end

  MALFORMED_CREDENTIAL_RUNTIME_MESSAGES = ["invalid type", "invalid id"].freeze
  AUTHENTICATION_CHALLENGE_SESSION_KEY = :webauthn_authentication_challenge

  private
    def build_webauthn_authentication_options
      webauthn_options = WebAuthn::Credential.options_for_get(user_verification: "required")
      session[AUTHENTICATION_CHALLENGE_SESSION_KEY] = webauthn_options.challenge
      webauthn_options.as_json.merge("rpId" => WebAuthn.configuration.rp_id)
    end

    def permitted_credential_params(**nested_filters)
      credential = params.require(:credential)
      raise VerificationError, "malformed_credential" unless credential.respond_to?(:permit)

      credential.permit(:id, :rawId, :type, :authenticatorAttachment, **nested_filters).to_h
    end

    def valid_credential_base?(permitted_params)
      permitted_params["type"] == "public-key" &&
        base64url_encoded?(permitted_params["id"]) &&
        base64url_encoded?(permitted_params["rawId"]) &&
        permitted_params["response"].is_a?(Hash)
    end

    def map_webauthn_verification_errors
      yield
    rescue VerificationError
      raise
    rescue ActionController::ParameterMissing, WebAuthn::Error, JSON::ParserError, CBOR::MalformedFormatError, CBOR::UnpackError, ArgumentError => e
      raise VerificationError, e.class.name
    rescue RuntimeError => e
      raise unless MALFORMED_CREDENTIAL_RUNTIME_MESSAGES.include?(e.message)

      raise VerificationError, e.class.name
    end

    def base64url_encoded?(value)
      !base64url_decoded(value).nil?
    end

    def base64url_decoded(value)
      return unless value.is_a?(String) && value.match?(/\A[A-Za-z0-9_-]+={0,2}\z/)

      Base64.urlsafe_decode64(value)
    rescue ArgumentError
      nil
    end

    def log_ceremony_failure(phase, reason, **context)
      attributes = context.map { |key, value| "#{key}=#{value}" }
      Rails.logger.warn(["passkey.#{phase}.failed", *attributes, "reason=#{reason}"].join(" "))
    end
end
