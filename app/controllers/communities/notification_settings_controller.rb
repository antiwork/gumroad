# frozen_string_literal: true

class Communities::NotificationSettingsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_community
  after_action :verify_authorized

  def update
    authorize @community, :show?

    settings = current_seller.community_notification_settings.find_or_initialize_by(seller: @community.seller)
    settings.update!(permitted_params)

    redirect_to community_path(@community.seller.external_id, @community.external_id),
                notice: "Changes saved!",
                status: :see_other
  end

  private
    def set_community
      @community = Community.alive.find_by_external_id!(params[:community_id])
    end

    def permitted_params
      params.permit(:recap_frequency)
    end
end
