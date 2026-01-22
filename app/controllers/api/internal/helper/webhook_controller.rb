# frozen_string_literal: true

class Api::Internal::Helper::WebhookController < Api::Internal::Helper::BaseController
  skip_before_action :authorize_helper_token!
  before_action :authorize_hmac_signature!
  before_action :require_params!

  def handle
    event = params[:event]
    payload = params[:payload]

    Rails.logger.info("Incoming Helper (conversation). event: #{event}, conversation_id: #{payload["conversation_id"]}")

    HandleHelperEventWorker.perform_async(event, payload.as_json)
    render json: { success: true }
  end

  private
    def require_params!
      render json: { success: false, error: "missing required parameters" }, status: :bad_request if params[:event].blank? || params[:payload].blank?
    end
end
