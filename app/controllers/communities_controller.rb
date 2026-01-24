# frozen_string_literal: true

class CommunitiesController < ApplicationController
  before_action :authenticate_user!
  after_action :verify_authorized

  layout "inertia"

  def index
    authorize Community

    presenter = CommunitiesPresenter.new(current_user: current_seller)
    render inertia: "Communities/Index", props: {
      **presenter.props,
      selected_seller_id: params[:seller_id],
      selected_community_id: params[:community_id]
    }
  end

  private
    def set_title
      @title = "Communities"
    end
end
