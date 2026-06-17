# frozen_string_literal: true

class Logins::PasskeysController < ApplicationController
  include WebauthnCeremonyVerification

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
    raise VerificationError, "missing_challenge" if challenge.blank?

    stored_credential = verified_credential(challenge)

    user = stored_credential.user
    raise VerificationError, "deleted_user" if user.deleted?

    stored_credential.save!

    user.remember_me = true
    sign_in(user)
    reset_two_factor_auth_login_session
    merge_guest_cart_with_user_cart
    refresh_passkey_setup_prompt(user)

    Rails.logger.info("passkey.authentication.succeeded user_id=#{user.id} webauthn_credential_id=#{stored_credential.id}")

    render json: { success: true, redirect_location: login_path_for(user) }
  rescue VerificationError => e
    log_authentication_failure(e.reason)
    render json: { success: false, error_message: AUTHENTICATION_ERROR_MESSAGE }, status: :unprocessable_entity
  end

  private
    def ensure_passkeys_feature_enabled
      e404 unless Feature.active?(:passkeys)
    end

    def verified_credential(challenge)
      map_webauthn_verification_errors do
        webauthn_credential = WebAuthn::Credential.from_get(assertion_params)
        stored_credential = WebauthnCredential.find_by_webauthn_id(webauthn_credential.id)
        raise VerificationError, "unknown_credential" if stored_credential.nil?

        webauthn_credential.verify(
          challenge,
          public_key: stored_credential.public_key,
          sign_count: stored_credential.sign_count,
          user_verification: true
        )

        stored_credential.assign_attributes(sign_count: webauthn_credential.sign_count, last_used_at: Time.current)
        stored_credential
      end
    end

    def assertion_params
      permitted_params = permitted_credential_params(response: [:authenticatorData, :clientDataJSON, :signature, :userHandle])
      raise VerificationError, "malformed_credential" unless valid_assertion_params?(permitted_params)

      permitted_params
    end

    def valid_assertion_params?(permitted_params)
      response = permitted_params["response"]

      valid_credential_base?(permitted_params) &&
        base64url_encoded?(response["authenticatorData"]) &&
        base64url_encoded?(response["clientDataJSON"]) &&
        base64url_encoded?(response["signature"])
    end

    def log_authentication_failure(reason)
      log_ceremony_failure("authentication", reason)
    end
end
