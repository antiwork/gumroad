# frozen_string_literal: true

class SecureRedirectController < ApplicationController
  layout "inertia"

  before_action :validate_params, only: [:new, :create]
  before_action :set_encrypted_params, only: [:new, :create]

  def new
    render inertia: "SecureRedirect/New", props: {
      message: @message,
      field_name: @field_name,
      error_message: @error_message,
      encrypted_payload: @encrypted_payload,
    }
  end

  def create
    confirmation_text = params[:confirmation_text]

    if confirmation_text.blank?
      return redirect_with_alert("Please enter the confirmation text")
    end

    # Decrypt and parse the bundled payload
    begin
      payload_json = SecureEncryptService.decrypt(@encrypted_payload)
      if payload_json.nil?
        return redirect_with_alert("Invalid request")
      end

      payload = JSON.parse(payload_json)
      destination = payload["destination"]
      confirmation_texts = payload["confirmation_texts"] || []
      send_confirmation_text = payload["send_confirmation_text"]

      # Verify the payload is recent (within 24 hours)
      if payload["created_at"] && Time.current.to_i - payload["created_at"] > 24.hours
        return redirect_with_alert("This link has expired")
      end

    rescue JSON::ParserError, NoMethodError
      return redirect_with_alert("Invalid request")
    end

    # Check if confirmation text matches any of the allowed texts
    if confirmation_texts.any? { |text| ActiveSupport::SecurityUtils.secure_compare(text, confirmation_text) }
      if send_confirmation_text
        begin
          uri = URI.parse(destination)
          query_params = Rack::Utils.parse_query(uri.query)
          query_params["confirmation_text"] = confirmation_text
          uri.query = query_params.to_query
          destination = uri.to_s
        rescue URI::InvalidURIError
          Rails.logger.error("Invalid destination: #{destination}")
        end
      end

      if destination.present?
        redirect_to destination, allow_other_host: true, status: :see_other
      else
        redirect_with_alert("Invalid destination")
      end
    else
      redirect_with_alert(@error_message)
    end
  end

  private
    def redirect_with_alert(alert_message)
      redirect_to secure_url_redirect_path(
        encrypted_payload: @encrypted_payload,
        message: @message,
        field_name: @field_name,
        error_message: @error_message
      ), alert: alert_message
    end

    def validate_params
      if params[:encrypted_payload].blank?
        redirect_to root_path
      end
    end

    def set_encrypted_params
      @encrypted_payload = params[:encrypted_payload]
      @message = params[:message].presence || "Please enter the confirmation text to continue to your destination."
      @field_name = params[:field_name].presence || "Confirmation text"
      @error_message = params[:error_message].presence || "Confirmation text does not match"
    end
end
