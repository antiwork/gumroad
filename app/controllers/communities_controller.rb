# frozen_string_literal: true

class CommunitiesController < ApplicationController
  before_action :authenticate_user!
  before_action :set_default_page_title
  after_action :verify_authorized

  layout "inertia"

  def index
    authorize Community

    props = CommunitiesPresenter.new(current_user: current_seller).props
    props[:selectedCommunityId] = params[:community_id] if params[:community_id].present?

    render inertia: "Communities/Index", props: props
  end

  private

  def set_default_page_title
    set_meta_tag(title: "Communities")
  end
end
