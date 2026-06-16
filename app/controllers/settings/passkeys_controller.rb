# frozen_string_literal: true

class Settings::PasskeysController < Settings::BaseController
  include WebauthnCeremonyVerification

  REGISTRATION_CHALLENGE_SESSION_KEY = :webauthn_registration_challenge
  REGISTRATION_ERROR_MESSAGE = "Could not add this passkey. Please try again."

  before_action :set_user
  before_action :ensure_passkeys_feature_enabled
  before_action :authorize
  before_action :set_webauthn_credential, only: %i[update destroy]

  def registration_options
    if @user.webauthn_credentials.count >= WebauthnCredential::MAX_PER_USER
      return render json: { success: false, error_message: WebauthnCredential::MAX_PER_USER_ERROR_MESSAGE }, status: :unprocessable_entity
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

    credential = @user.with_lock do
      @user.webauthn_credentials.create!(
        webauthn_id: webauthn_credential.id,
        public_key: webauthn_credential.public_key,
        sign_count: webauthn_credential.sign_count,
        nickname: params[:nickname].presence || detected_provider_name(webauthn_credential)
      )
    end

    Rails.logger.info("passkey.registration.succeeded user_id=#{@user.id} webauthn_credential_id=#{credential.id}")

    refresh_passkey_setup_prompt(logged_in_user)

    render json: { success: true, passkey: passkey_props(credential) }, status: :created
  rescue VerificationError => e
    log_registration_failure(e.reason)
    render json: { success: false, error_message: REGISTRATION_ERROR_MESSAGE }, status: :unprocessable_entity
  rescue ActiveRecord::RecordInvalid => e
    reason = max_passkeys_error?(e.record) ? "max_passkeys" : "invalid_record"
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
      permitted_params = permitted_credential_params(
        response: [:attestationObject, :clientDataJSON, { transports: [] }],
        clientExtensionResults: {}
      )
      raise VerificationError, "malformed_credential" unless valid_credential_params?(permitted_params)

      permitted_params
    end

    def verified_webauthn_credential(challenge)
      map_webauthn_verification_errors do
        WebAuthn::Credential.from_create(credential_params).tap do |credential|
          credential.verify(challenge, user_verification: true)
        end
      end
    end

    def detected_provider_name(webauthn_credential)
      WebauthnCredential.provider_name_for_aaguid(webauthn_credential.response&.authenticator_data&.aaguid)
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
      max_passkeys_error?(record) ? WebauthnCredential::MAX_PER_USER_ERROR_MESSAGE : REGISTRATION_ERROR_MESSAGE
    end

    def max_passkeys_error?(record)
      record.errors.details[:base].any? { _1[:error] == WebauthnCredential::MAX_PER_USER_ERROR }
    end

    def valid_credential_params?(permitted_params)
      response = permitted_params["response"]

      valid_credential_base?(permitted_params) &&
        valid_attestation_object?(response["attestationObject"]) &&
        valid_client_data_json?(response["clientDataJSON"])
    end

    def valid_attestation_object?(encoded_attestation_object)
      attestation_object = CBOR.decode(base64url_decoded(encoded_attestation_object))

      attestation_object.is_a?(Hash) &&
        attestation_object["fmt"].is_a?(String) &&
        attestation_object["attStmt"].is_a?(Hash) &&
        attestation_object["authData"].is_a?(String)
    rescue CBOR::MalformedFormatError, CBOR::UnpackError, TypeError
      false
    end

    def valid_client_data_json?(encoded_client_data_json)
      client_data = JSON.parse(base64url_decoded(encoded_client_data_json))

      client_data.is_a?(Hash) &&
        client_data["type"].is_a?(String) &&
        client_data["challenge"].is_a?(String) &&
        client_data["origin"].is_a?(String)
    rescue JSON::ParserError, TypeError
      false
    end

    def log_registration_failure(reason)
      log_ceremony_failure("registration", reason, user_id: @user.id)
    end
end
