# frozen_string_literal: true

class SupportController < ApplicationController
  include ValidateRecaptcha
  include HelperWidget

  def index
    return redirect_to help_center_root_path(params.permit(:new_ticket)) unless user_signed_in?

    e404 if helper_widget_host.blank?

    @title = "Support"
    @props = {
      host: helper_widget_host,
      session: helper_session,
    }
  end

  def create_unauthenticated_ticket
    return unless validate_request_params
    return render json: { error: "reCAPTCHA verification failed" }, status: :unprocessable_entity unless valid_recaptcha_response?(site_key: GlobalConfig.get("RECAPTCHA_LOGIN_SITE_KEY"))

    email = params[:email].strip.downcase
    subject = params[:subject].strip
    message = params[:message].strip

    begin
      conversation_slug = create_helper_conversation(email: email, subject: subject, message: message)
      render json: { success: true, conversation_slug: conversation_slug }
    rescue
      render json: { error: "Failed to create support ticket" }, status: :internal_server_error
    end
  end

  private
    def validate_request_params
      missing_params = []
      missing_params << "email" if params[:email].blank?
      missing_params << "subject" if params[:subject].blank?
      missing_params << "message" if params[:message].blank?
      missing_params << "g-recaptcha-response" if params["g-recaptcha-response"].blank? && !Rails.env.test?

      if missing_params.any?
        render json: { error: "Missing required parameters: #{missing_params.join(', ')}" }, status: :bad_request
        return false
      end

      unless valid_email?(params[:email].strip.downcase)
        render json: { error: "Invalid email address" }, status: :bad_request
        return false
      end

      true
    end

    def valid_email?(email)
      email.match?(URI::MailTo::EMAIL_REGEXP)
    end

    def create_helper_conversation(email:, subject:, message:)
      timestamp = (Time.current.to_f * 1000).to_i
      email_hash = helper_widget_email_hmac(timestamp, email: email)

      response = create_conversation_via_api(
        subject: subject,
        from_email: email,
        message: message,
        timestamp: timestamp,
        email_hash: email_hash
      )

      if response.success?
        response.parsed_response["conversation_slug"]
      else
        raise "Helper API error: #{response.code} - #{response.body}"
      end
    end

    def create_conversation_via_api(params)
      helper_host = GlobalConfig.get("HELPER_WIDGET_HOST")
      raise "Helper widget host not configured" unless helper_host.present?

      guest_session = {
        email: params[:from_email],
        emailHash: params[:email_hash],
        timestamp: params[:timestamp]
      }

      session_response = HTTParty.post(
        "#{helper_host}/api/widget/session",
        body: guest_session.to_json
      )

      unless session_response.success?
        raise "Helper session creation failed: #{session_response.code}"
      end
      helper_token = session_response.parsed_response["token"]

      conversation_response = HTTParty.post(
        "#{helper_host}/api/chat/conversation",
        headers: {
          "Authorization" => "Bearer #{helper_token}"
        },
        body: { subject: params[:subject] }.to_json
      )

      unless conversation_response.success?
        raise "Helper conversation creation failed: #{conversation_response.code}"
      end

      conversation_slug = conversation_response.parsed_response["conversationSlug"]

      message_response = HTTParty.post(
        "#{helper_host}/api/chat/conversation/#{conversation_slug}/message",
        headers: {
          "Authorization" => "Bearer #{helper_token}"
        },
        body: {
          content: params[:message],
          customerInfoUrl: user_info_api_internal_helper_users_url(host: API_DOMAIN)
        }.to_json
      )

      unless message_response.success?
        raise "Helper message creation failed: #{message_response.code}"
      end

      OpenStruct.new(
        success?: true,
        parsed_response: { "conversation_slug" => conversation_slug }
      )
    end
end
