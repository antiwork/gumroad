# frozen_string_literal: true

class Logins::PasskeysController < ApplicationController
  class AuthenticationVerificationError < StandardError
    attr_reader :reason

    def initialize(reason)
      @reason = reason
      super(reason)
    end
  end

  AUTHENTICATION_CHALLENGE_SESSION_KEY = :webauthn_authentication_challenge
  AUTHENTICATION_ERROR_MESSAGE = "We couldn't sign you in with that passkey. Please try again or use your password."

  skip_before_action :check_suspended
  skip_before_action :invalidate_session_if_necessary
  before_action :ensure_passkeys_feature_enabled

  def options
    webauthn_options = WebAuthn::Credential.options_for_get(user_verification: "required")

    session[AUTHENTICATION_CHALLENGE_SESSION_KEY] = webauthn_options.challenge

    render json: { success: true, options: webauthn_options.as_json.merge("rpId" => WebAuthn.configuration.rp_id) }
  end

  def create
    challenge = session.delete(AUTHENTICATION_CHALLENGE_SESSION_KEY)
    raise AuthenticationVerificationError, "missing_challenge" if challenge.blank?

    stored_credential = verified_credential(challenge)

    user = stored_credential.user
    raise AuthenticationVerificationError, "deleted_user" if user.deleted?

    stored_credential.save!

    user.remember_me = true
    sign_in(user)
    reset_two_factor_auth_login_session
    merge_guest_cart_with_user_cart

    Rails.logger.info("passkey.authentication.succeeded user_id=#{user.id} webauthn_credential_id=#{stored_credential.id}")

    render json: { success: true, redirect_location: login_path_for(user) }
  rescue AuthenticationVerificationError => e
    log_authentication_failure(e.reason)
    render json: { success: false, error_message: AUTHENTICATION_ERROR_MESSAGE }, status: :unprocessable_entity
  end

  private
    def ensure_passkeys_feature_enabled
      e404 unless Feature.active?(:passkeys)
    end

    def verified_credential(challenge)
      webauthn_credential = WebAuthn::Credential.from_get(assertion_params)
      stored_credential = WebauthnCredential.find_by_webauthn_id(webauthn_credential.id)
      raise AuthenticationVerificationError, "unknown_credential" if stored_credential.nil?

      webauthn_credential.verify(
        challenge,
        public_key: stored_credential.public_key,
        sign_count: stored_credential.sign_count,
        user_verification: true
      )

      stored_credential.assign_attributes(sign_count: webauthn_credential.sign_count, last_used_at: Time.current)
      stored_credential
    rescue AuthenticationVerificationError
      raise
    rescue ActionController::ParameterMissing, WebAuthn::Error, JSON::ParserError, CBOR::MalformedFormatError, CBOR::UnpackError, ArgumentError => e
      raise AuthenticationVerificationError, e.class.name
    rescue RuntimeError => e
      raise unless ["invalid type", "invalid id"].include?(e.message)

      raise AuthenticationVerificationError, e.class.name
    end

    def assertion_params
      credential = params.require(:credential)
      raise AuthenticationVerificationError, "malformed_credential" unless credential.respond_to?(:permit)

      permitted_params = credential.permit(
        :id,
        :rawId,
        :type,
        :authenticatorAttachment,
        response: [:authenticatorData, :clientDataJSON, :signature, :userHandle]
      ).to_h

      raise AuthenticationVerificationError, "malformed_credential" unless valid_assertion_params?(permitted_params)

      permitted_params
    end

    def valid_assertion_params?(permitted_params)
      response = permitted_params["response"]

      permitted_params["type"] == "public-key" &&
        base64url?(permitted_params["id"]) &&
        base64url?(permitted_params["rawId"]) &&
        response.is_a?(Hash) &&
        base64url?(response["authenticatorData"]) &&
        base64url?(response["clientDataJSON"]) &&
        base64url?(response["signature"])
    end

    def base64url?(value)
      value.is_a?(String) && value.match?(/\A[A-Za-z0-9_-]+={0,2}\z/)
    end

    def log_authentication_failure(reason)
      Rails.logger.warn("passkey.authentication.failed reason=#{reason}")
    end
end
