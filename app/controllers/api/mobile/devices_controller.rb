# frozen_string_literal: true

class Api::Mobile::DevicesController < Api::Mobile::BaseController
  before_action { doorkeeper_authorize! :creator_api, :mobile_api }

  def create
    # A brand token keeps the phone on its team member, so brand sales stop reaching it once the
    # membership ends.
    device = (impersonated_user || account_holder).devices.build(device_params)

    if save_device(device)
      render json: { success: true }, status: :created
    else
      render json: { success: false }, status: :unprocessable_entity
    end
  end

  private
    def device_params
      params.require(:device).permit(:token, :device_type, :app_type, :app_version)
    end

    # The app re-registers when its access token changes mid-launch, so two registrations of the
    # same token can overlap. Both delete the token's existing rows before inserting, so the loser
    # hits the unique index on (token, device_type) after the winner committed. Retrying once
    # replaces the winner's row, which leaves the device registered either way.
    def save_device(device)
      retried = false

      begin
        device.save
      rescue ActiveRecord::RecordNotUnique
        return false if retried

        retried = true
        retry
      end
    end
end
