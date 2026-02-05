# frozen_string_literal: true

class Api::Internal::Communities::NotificationSettingsController < Api::Internal::BaseController
  before_action :authenticate_user!
  before_action :set_community
  after_action :verify_authorized

  def update
    settings = current_seller.community_notification_settings.find_or_initialize_by(seller: @community.seller)
    settings.update!(permitted_params)

    render json: { settings: CommunityNotificationSettingPresenter.new(settings:).props }
  end

  private
    def set_community
      @community = Community.find_by_external_id(params[:community_id])
      return e404_json unless @community
      authorize @community, :show?
    end

    def permitted_params
      params.require(:settings).permit(:recap_frequency)
    end
end
