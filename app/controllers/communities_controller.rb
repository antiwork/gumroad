# frozen_string_literal: true

class CommunitiesController < ApplicationController
  before_action :authenticate_user!
  before_action :set_community, only: [:show]
  after_action :verify_authorized
  before_action :set_body_id_as_app

  def index

    authorize Community

    render inertia: 'Communities/Index',
           props: CommunitiesPresenter.new(current_user: current_seller).props
  end

  def show
    render inertia: 'Communities/Show',
           props: {
             community: CommunityPresenter.new(community: @community, current_user: current_seller).props,
             messages: PaginatedCommunityChatMessagesPresenter.new(
               community: @community,
               timestamp: Time.current.iso8601,
               fetch_type: 'older'
             ).props[:messages]
           }
  end

  private
    def set_title
      @title = "Communities"
    end

    def set_community
      external_id = params[:id] || params[:community_iid]
      @community = Community.find_by_external_id(external_id)
      return head :not_found unless @community

      authorize @community, :show?
    end
end
