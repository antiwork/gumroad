# frozen_string_literal: true

class SecureRedirectController < ApplicationController
  before_action :validate_params, only: [:new, :create]
  before_action :set_encrypted_params, only: [:new, :create]
  before_action :set_react_component_props, only: [:new, :create]

  def new
  end

  def create
    confirmation_text = params[:confirmation_text]

    if confirmation_text.blank?
      return render json: { error: "Please enter the confirmation text" }, status: :unprocessable_entity
    end

    if SecureEncryptService.verify(@encrypted_confirmation_text, confirmation_text)
      destination = SecureEncryptService.decrypt(@encrypted_destination)

      if destination.present?
        redirect_to destination
      else
        render json: { error: "Invalid destination" }, status: :unprocessable_entity
      end
    else
      render json: { error: @error_message }, status: :unprocessable_entity
    end
  end

  private
    def validate_params
      if params[:encrypted_destination].blank? || params[:encrypted_confirmation_text].blank?
        redirect_to root_path
      end
    end

    def set_encrypted_params
      @encrypted_destination = params[:encrypted_destination]
      @encrypted_confirmation_text = params[:encrypted_confirmation_text]
      @message = params[:message].presence || "Please enter the confirmation text to continue to your destination."
      @field_name = params[:field_name].presence || "Confirmation text"
      @error_message = params[:error_message].presence || "Confirmation text does not match"
    end

    def set_react_component_props
      props = {
        message: @message,
        field_name: @field_name,
        error_message: @error_message,
        encrypted_destination: @encrypted_destination,
        encrypted_confirmation_text: @encrypted_confirmation_text,
        form_action: secure_url_redirect_path,
        authenticity_token: form_authenticity_token
      }

      props[:flash_error] = flash[:error] if flash[:error].present?

      @react_component_props = props
    end
end
