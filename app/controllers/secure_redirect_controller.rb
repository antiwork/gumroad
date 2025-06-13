# frozen_string_literal: true

class SecureRedirectController < ApplicationController
  before_action :validate_params, only: [:new, :create]
  before_action :set_encrypted_params, only: [:new, :create]

  def new
  end

  def create
    confirmation_text = params[:confirmation_text]

    if confirmation_text.blank?
      flash[:error] = "Please enter the confirmation text"
      render :new and return
    end

    if SecureEncryptService.verify(@encrypted_confirmation_text, confirmation_text)
      destination = SecureEncryptService.decrypt(@encrypted_destination)

      if destination.present?
        redirect_to destination, allow_other_host: true
      else
        flash[:error] = "Invalid destination"
        render :new
      end
    else
      flash[:error] = @error_message
      render :new
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
end
