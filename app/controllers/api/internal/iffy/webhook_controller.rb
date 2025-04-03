# frozen_string_literal: true

class Api::Internal::Iffy::WebhookController < Api::Internal::BaseController
  skip_before_action :verify_authenticity_token
  before_action :authorize_hmac_signature!

  HMAC_EXPIRATION = 1.minute

  def handle
    event = params.require(:event)
    payload = params.require(:payload).permit(:clientId, :entity, user: [:protected])

    user_data = payload[:user]&.as_json if payload[:user].present?

    Iffy::EventJob.perform_async(
      event,
      payload[:clientId],
      payload[:entity],
      user_data
    )

    head :ok
  end

  private
    def authorize_hmac_signature!
      timestamp = params.require(:timestamp).to_i
      return render json: { success: false, message: "timestamp is required" }, status: :bad_request if timestamp.blank?

      signature = request.headers["HTTP_X_SIGNATURE"]
      return render json: { success: false, message: "signature is required" }, status: :unauthorized if signature.blank?

      if (timestamp / 1000.0 - Time.now.to_f).abs > HMAC_EXPIRATION
        return render json: { success: false, message: "bad timestamp" }, status: :unauthorized
      end

      body = request.body.read
      expected_signature = OpenSSL::HMAC.hexdigest("sha256", GlobalConfig.get("IFFY_WEBHOOK_SECRET"), body)
      unless ActiveSupport::SecurityUtils.secure_compare(signature, expected_signature)
        render json: { success: false, message: "signature is invalid" }, status: :unauthorized
      end
    end
end
