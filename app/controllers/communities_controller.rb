# frozen_string_literal: true

class CommunitiesController < ApplicationController
  before_action :authenticate_user!
  before_action :set_default_page_title
  after_action :verify_authorized

  layout "inertia"

  def index
    authorize Community

    props = CommunitiesPresenter.new(current_user: current_seller).props

    render inertia: "Communities/Index", props: props
  end

  def show
    seller = User.find_by_external_id!(params[:seller_id])
    community = Community.alive.find_by_external_id!(params[:community_id])

    raise ActiveRecord::RecordNotFound unless community.seller_id == seller.id

    authorize community

    props = CommunitiesPresenter.new(current_user: current_seller).props
    props[:selectedCommunityId] = community.external_id

    render inertia: "Communities/Index", props: props
  end

  private

  def set_default_page_title
    set_meta_tag(title: "Communities")
  end
end
