# frozen_string_literal: true

class CommunitiesController < ApplicationController
  before_action :authenticate_user!
  after_action :verify_authorized
  before_action :set_community, only: [:show, :update_notification_settings]
  before_action :set_default_page_title

  layout "inertia"

  def index
    authorize Community

    if presenter.first_community
      redirect_to community_path(presenter.first_community.seller.external_id, presenter.first_community.external_id)
    else
      render inertia: "Communities/Index", props: presenter.props
    end
  end

  def show
    authorize @community

    render inertia: "Communities/Index", props: presenter.props(selected_community_id: @community.external_id)
  end

  def update_notification_settings
    authorize @community, :show?

    settings = current_seller.community_notification_settings.find_or_initialize_by(seller: @community.seller)
    settings.update!(notification_settings_params)

    redirect_back fallback_location: community_path(@community.seller.external_id, @community.external_id),
                  notice: "Changes saved!"
  end

  private
    def set_default_page_title
      set_meta_tag(title: "Communities")
    end

    def set_community
      @community = Community.find_by_external_id!(params[:community_id])
    end

    def notification_settings_params
      params.permit(:recap_frequency)
    end

    def presenter
      @presenter ||= CommunitiesPresenter.new(current_user: current_seller)
    end
end
