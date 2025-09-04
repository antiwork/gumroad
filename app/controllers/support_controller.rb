# frozen_string_literal: true

class SupportController < ApplicationController
  include ValidateRecaptcha
  include HelperWidget

  def index
    skip_authorization

    e404 if helper_widget_host.blank?

    @title = "Support"
    @props = {
      host: helper_widget_host,
      session: helper_session,
      recaptcha_site_key: user_signed_in? ? nil : GlobalConfig.get("RECAPTCHA_SUPPORT_SITE_KEY"),
    }
  end

  def create_unauthenticated_ticket
    skip_authorization

    unless valid_new_ticket_params?
      return render json: { error: "missing_params", message: "Missing required parameters" }, status: :bad_request
    end

    unless valid_recaptcha_response?(site_key: GlobalConfig.get("RECAPTCHA_SUPPORT_SITE_KEY"))
      return render json: { error: "recaptcha_failed", message: "reCAPTCHA verification failed" }, status: :unprocessable_entity
    end

    email   = params[:email].to_s.strip.downcase
    subject = params[:subject].to_s.strip
    message = params[:message].to_s.strip

    begin
      slug = Helper::CreateConversationService.new(email:, subject:, message:).call
      render json: { success: true, conversation_slug: slug }
    rescue => e
      Rails.logger.error "Failed to create Helper conversation: #{e.class}: #{e.message}"
      render json: { error: "helper_failed", message: "Failed to create support ticket" }, status: :internal_server_error
    end
  end

  private
    def valid_new_ticket_params?
      email   = params[:email].to_s
      subject = params[:subject].to_s
      message = params[:message].to_s
      token   = params["g-recaptcha-response"].to_s

      email.present? && email.match?(URI::MailTo::EMAIL_REGEXP) &&
        subject.strip.present? && subject.length <= 200 &&
        message.strip.present? && message.length <= 10_000 &&
        token.present?
    end
end
