# frozen_string_literal: true

class Settings::TotpController < Settings::BaseController
  before_action :set_user
  before_action :authorize

  def create
    if @user.totp_enabled?
      return render json: { success: false, error_message: "Authenticator app is already enabled." }, status: :unprocessable_entity
    end

    @user.totp_credential&.destroy

    credential = @user.create_totp_credential!
    uri = credential.totp_provisioning_uri
    qr_svg = RQRCode::QRCode.new(uri).as_svg(
      module_size: 4,
      offset: 16,
      fill: "ffffff",
      use_path: true,
      viewbox: true
    )

    render json: {
      success: true,
      secret: credential.otp_secret,
      provisioning_uri: uri,
      qr_svg:
    }
  end

  def confirm
    credential = @user.totp_credential
    if credential.blank?
      return render json: { success: false, error_message: "No pending TOTP setup found." }, status: :unprocessable_entity
    end

    result = nil
    codes = nil
    credential.with_lock do
      if credential.confirmed?
        result = :missing
      elsif credential.verify_code(params[:code])
        credential.update!(confirmed_at: Time.current)
        codes = credential.generate_recovery_codes
        result = :ok
      else
        result = :invalid
      end
    end

    case result
    when :ok
      render json: { success: true, recovery_codes: format_recovery_codes(codes) }
    when :invalid
      render json: { success: false, error_message: "Invalid code. Please try again." }, status: :unprocessable_entity
    else
      render json: { success: false, error_message: "No pending TOTP setup found." }, status: :unprocessable_entity
    end
  end

  def destroy
    unless @user.totp_enabled?
      return render json: { success: false, error_message: "Authenticator app is not enabled." }, status: :unprocessable_entity
    end

    @user.totp_credential.destroy!

    render json: { success: true }
  end

  def regenerate_recovery_codes
    unless @user.totp_enabled?
      return render json: { success: false, error_message: "Authenticator app is not enabled." }, status: :unprocessable_entity
    end

    codes = @user.totp_credential.generate_recovery_codes

    render json: { success: true, recovery_codes: format_recovery_codes(codes) }
  end

  private
    def set_user
      @user = current_seller
    end

    def authorize
      super([:settings, :totp, @user])
    end

    def format_recovery_codes(codes)
      midpoint = TotpCredential::RECOVERY_CODE_LENGTH / 2
      codes.map { |code| "#{code[0...midpoint]}-#{code[midpoint..]}" }
    end
end
