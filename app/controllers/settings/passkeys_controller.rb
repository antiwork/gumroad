# frozen_string_literal: true

class Settings::PasskeysController < Settings::BaseController
  class RegistrationVerificationError < StandardError
    attr_reader :reason

    def initialize(reason)
      @reason = reason
      super(reason)
    end
  end

  REGISTRATION_CHALLENGE_SESSION_KEY = :webauthn_registration_challenge
  REGISTRATION_ERROR_MESSAGE = "Could not add this passkey. Please try again."
  MAX_PASSKEYS_ERROR_MESSAGE = "You can add up to #{WebauthnCredential::MAX_PER_USER} passkeys."

  before_action :set_user
  before_action :ensure_passkeys_feature_enabled
  before_action :authorize
  before_action :set_webauthn_credential, only: %i[update destroy]

  def registration_options
    if @user.webauthn_credentials.count >= WebauthnCredential::MAX_PER_USER
      return render json: { success: false, error_message: MAX_PASSKEYS_ERROR_MESSAGE }, status: :unprocessable_entity
    end

    options = WebAuthn::Credential.options_for_create(
      user: {
        id: @user.external_id,
        name: @user.email,
        display_name: @user.display_name(prefer_email_over_default_username: true)
      },
      exclude: @user.webauthn_credentials.pluck(:webauthn_id),
      authenticator_selection: {
        resident_key: "required",
        user_verification: "required"
      },
      attestation: "none"
    )

    session[REGISTRATION_CHALLENGE_SESSION_KEY] = options.challenge

    render json: { success: true, options: options.as_json }
  end

  def create
    challenge = session.delete(REGISTRATION_CHALLENGE_SESSION_KEY)
    if challenge.blank?
      log_registration_failure("missing_challenge")
      return render json: { success: false, error_message: REGISTRATION_ERROR_MESSAGE }, status: :unprocessable_entity
    end

    webauthn_credential = verified_webauthn_credential(challenge)

    credential = @user.webauthn_credentials.create!(
      webauthn_id: webauthn_credential.id,
      public_key: webauthn_credential.public_key,
      sign_count: webauthn_credential.sign_count,
      nickname: params[:nickname]
    )

    Rails.logger.info("passkey.registration.succeeded user_id=#{@user.id} webauthn_credential_id=#{credential.id}")

    render json: { success: true, passkey: passkey_props(credential) }, status: :created
  rescue RegistrationVerificationError => e
    log_registration_failure(e.reason)
    render json: { success: false, error_message: REGISTRATION_ERROR_MESSAGE }, status: :unprocessable_entity
  rescue ActiveRecord::RecordInvalid => e
    reason = e.record.errors[:base].include?(MAX_PASSKEYS_ERROR_MESSAGE) ? "max_passkeys" : "invalid_record"
    log_registration_failure(reason)
    render json: { success: false, error_message: registration_error_message(e.record) }, status: :unprocessable_entity
  rescue ActiveRecord::RecordNotUnique => e
    log_registration_failure(e.class.name)
    render json: { success: false, error_message: REGISTRATION_ERROR_MESSAGE }, status: :unprocessable_entity
  end

  def update
    @webauthn_credential.update!(nickname: params[:nickname])

    render json: { success: true, passkey: passkey_props(@webauthn_credential) }
  rescue ActiveRecord::RecordInvalid
    render json: { success: false, error_message: "Could not update this passkey." }, status: :unprocessable_entity
  end

  def destroy
    @webauthn_credential.destroy!

    render json: { success: true }
  end

  private
    def set_user
      @user = current_seller
    end

    def ensure_passkeys_feature_enabled
      e404 unless Feature.active?(:passkeys, @user)
    end

    def authorize
      super([:settings, :passkeys, @user])
    end

    def set_webauthn_credential
      @webauthn_credential = @user.webauthn_credentials.find_by_external_id(params[:id]) || e404
    end

    def credential_params
      params.require(:credential).permit!.to_h
    end

    def verified_webauthn_credential(challenge)
      WebAuthn::Credential.from_create(credential_params).tap do |credential|
        credential.verify(challenge, user_verification: true)
      end
    rescue StandardError => e
      raise RegistrationVerificationError, e.class.name
    end

    def passkey_props(credential)
      {
        id: credential.external_id,
        nickname: credential.nickname,
        created_at: credential.created_at,
        last_used_at: credential.last_used_at
      }
    end

    def registration_error_message(record)
      record.errors[:base].include?(MAX_PASSKEYS_ERROR_MESSAGE) ? MAX_PASSKEYS_ERROR_MESSAGE : REGISTRATION_ERROR_MESSAGE
    end

    def log_registration_failure(reason)
      Rails.logger.warn("passkey.registration.failed user_id=#{@user.id} reason=#{reason}")
    end
end
