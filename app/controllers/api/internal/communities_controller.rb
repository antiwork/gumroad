# frozen_string_literal: true

class Api::Internal::CommunitiesController < Api::Internal::BaseController
  before_action :authenticate_user!
  after_action :verify_authorized

  def index
    authorize Community

    render json: CommunitiesPresenter.new(current_user: current_seller).props
  end
end
