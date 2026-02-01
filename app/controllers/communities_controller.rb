# frozen_string_literal: true

class CommunitiesController < ApplicationController
  before_action :authenticate_user!
  before_action :set_default_page_title
  before_action :set_community, only: [:show, :update_notification_settings]
  after_action :verify_authorized

  layout "inertia"

  def index
    authorize Community

    presenter = CommunitiesPresenter.new(current_user: current_seller)

    render inertia: "Communities/Index", props: {
      has_products: -> { presenter.props[:has_products] },
      communities: -> { presenter.props[:communities] },
      notification_settings: -> { presenter.props[:notification_settings] }
    }
  end

  def show
    authorize @community

    presenter = CommunitiesPresenter.new(current_user: current_seller)

    render inertia: "Communities/Index", props: {
      has_products: -> { presenter.props[:has_products] },
      communities: -> { presenter.props[:communities] },
      notification_settings: -> { presenter.props[:notification_settings] },
      selectedCommunityId: @community.external_id
    }
  end

  def update_notification_settings
    authorize @community, :show?

    settings = current_seller.community_notification_settings.find_or_initialize_by(seller: @community.seller)
    settings.update!(permitted_notification_params)

    redirect_to community_path(@community.seller.external_id, @community.external_id),
                notice: "Changes saved!",
                status: :see_other
  end

  private

  def set_default_page_title
    set_meta_tag(title: "Communities")
  end

  def set_community
    seller = User.find_by_external_id!(params[:seller_id])
    @community = Community.alive.find_by_external_id!(params[:community_id])

    raise ActiveRecord::RecordNotFound unless @community.seller_id == seller.id
  end

  def permitted_notification_params
    params.permit(:recap_frequency)
  end
end
