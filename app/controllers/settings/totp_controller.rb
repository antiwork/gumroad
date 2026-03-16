# frozen_string_literal: true

class Settings::TotpController < Settings::BaseController
  before_action :set_user
  before_action :authorize

  def create
    if @user.totp_enabled?
      return render json: { success: false, error_message: "Authenticator app is already enabled." }, status: :unprocessable_entity
    end

    @user.totp_credential&.destroy unless @user.totp_credential&.confirmed?

    credential = @user.create_totp_credential!
    uri = credential.totp_provisioning_uri
    qr_svg = RQRCode::QRCode.new(uri).as_svg(module_size: 4, use_path: true)

    render json: {
      success: true,
      secret: credential.otp_secret,
      provisioning_uri: uri,
      qr_svg:
    }
  end

  def confirm
    credential = @user.totp_credential

    if credential.blank? || credential.confirmed?
      return render json: { success: false, error_message: "No pending TOTP setup found." }, status: :unprocessable_entity
    end

    if credential.verify_code(params[:code])
      credential.update!(confirmed_at: Time.current)
      codes = credential.generate_recovery_codes

      render json: { success: true, recovery_codes: codes }
    else
      render json: { success: false, error_message: "Invalid code. Please try again." }, status: :unprocessable_entity
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
    credential = @user.totp_credential

    unless credential&.confirmed?
      return render json: { success: false, error_message: "Authenticator app is not enabled." }, status: :unprocessable_entity
    end

    codes = credential.generate_recovery_codes

    render json: { success: true, recovery_codes: codes }
  end

  private
    def set_user
      @user = current_seller
    end

    def authorize
      super([:settings, :totp, @user])
    end
end
