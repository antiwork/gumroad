# frozen_string_literal: true

class SecureRedirectController < ApplicationController
  layout "inertia"

  before_action :validate_params, only: [:new, :create]
  before_action :set_encrypted_params, only: [:new, :create]
  before_action :set_react_component_props, only: [:new]

  def new
    render inertia: "SecureRedirect/New", props: @react_component_props
  end

  def create
    confirmation_text = params[:confirmation_text]

    if confirmation_text.blank?
      return validation_error(confirmation_text: "Please enter the confirmation text")
    end

    # Decrypt and parse the bundled payload
    begin
      payload_json = SecureEncryptService.decrypt(@encrypted_payload)
      if payload_json.nil?
        return global_error("Invalid request")
      end

      payload = JSON.parse(payload_json)
      destination = payload["destination"]
      confirmation_texts = payload["confirmation_texts"] || []
      send_confirmation_text = payload["send_confirmation_text"]

      # Verify the payload is recent (within 24 hours)
      if payload["created_at"] && Time.current.to_i - payload["created_at"] > 24.hours
        return global_error("This link has expired")
      end

    rescue JSON::ParserError, NoMethodError
      return global_error("Invalid request")
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
        inertia_location destination
      else
        global_error("Invalid destination")
      end
    else
      validation_error(confirmation_text: @error_message)
    end
  end

  private
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

    def set_react_component_props
      props = {
        message: @message,
        field_name: @field_name,
        error_message: @error_message,
        encrypted_payload: @encrypted_payload,
        form_action: secure_url_redirect_path,
        authenticity_token: form_authenticity_token
      }

      props[:flash_error] = flash[:error] if flash[:error].present?

      @react_component_props = props
    end

    def validation_error(errors)
      redirect_back fallback_location: secure_url_redirect_path(encrypted_payload: @encrypted_payload), inertia: { errors: errors }
    end

    def global_error(message)
      flash[:alert] = message
      redirect_back fallback_location: secure_url_redirect_path(encrypted_payload: @encrypted_payload)
    end
end
