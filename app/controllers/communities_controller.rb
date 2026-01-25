# frozen_string_literal: true

class CommunitiesController < ApplicationController
  before_action :authenticate_user!
  before_action :set_community, if: -> { params[:community_id].present? }
  before_action :set_title
  after_action :verify_authorized

  layout "inertia"

  def index
    authorize Community

    props = CommunitiesPresenter.new(current_user: current_seller).props

    if @community
      props = props.merge(selectedCommunityId: @community.external_id)
    end

    render inertia: "Communities/Index", props: props
  end

  private
    def set_title
      @title = "Communities"
    end

    def set_community
      external_id = params[:community_id]
      @community = Community.find_by_external_id(external_id)
      return head :not_found unless @community

      authorize @community, :show?
    end
end
