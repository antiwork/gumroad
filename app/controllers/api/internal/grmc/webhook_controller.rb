# frozen_string_literal: true

class Api::Internal::Grmc::WebhookController < Api::Internal::BaseController
  skip_before_action :verify_authenticity_token
  before_action :authorize_hmac_signature!

  def handle
    HandleGrmcCallbackJob.perform_async(JSON.parse(request.body.read))
    head :ok
  end

  private
    def authorize_hmac_signature!
      timestamp, signature = request.headers["HTTP_GRMC_SIGNATURE"].to_s.scan(/([^,=]+)=([^,=]+)/).to_h.slice("t", "v0").values
      if (timestamp.to_i / 1000.0 - Time.current.to_f).abs <= 1.minute
        expected_signature = OpenSSL::HMAC.hexdigest("sha256", GlobalConfig.get("GRMC_WEBHOOK_SECRET"), request.body.read)
        return true if ActiveSupport::SecurityUtils.secure_compare(signature.to_s, expected_signature)
      end

      render json: { success: false, message: "invalid timestamp or signature" }, status: :unauthorized
    end
end
