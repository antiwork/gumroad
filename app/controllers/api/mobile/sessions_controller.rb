# frozen_string_literal: true

class Api::Mobile::SessionsController < Api::Mobile::BaseController
  before_action { doorkeeper_authorize! :mobile_api }
  skip_before_action :verify_authenticity_token, only: :create

  def create
    sign_in current_resource_owner

    render json: { success: true, user: { email: current_resource_owner.form_email } }
  end

  def resend_confirmation_email
    user = current_resource_owner
    return render json: { success: true, status: "already_confirmed" } unless user.has_unconfirmed_email?

    return render json: { success: true, status: "sent" } if user.resend_confirmation_instructions

    render json: {
      success: false,
      status: "throttled",
      retry_after: user.reload.resend_confirmation_wait,
      message: "We just sent a confirmation email. Please wait a minute before asking for another.",
    }, status: :too_many_requests
  end
end
