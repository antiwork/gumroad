# frozen_string_literal: true

class Api::Mobile::DevicesController < Api::Mobile::BaseController
  before_action { doorkeeper_authorize! :creator_api, :mobile_api }

  def create
    device = current_resource_owner.devices.build(device_params)

    begin
      saved = device.save
    rescue ActiveRecord::RecordNotUnique
      saved = false
    end

    if saved
      render json: { success: true }, status: :created
    else
      render json: { success: false }, status: :unprocessable_entity
    end
  end

  private
    def device_params
      params.require(:device).permit(:token, :device_type, :app_type, :app_version)
    end
end
