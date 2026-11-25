# frozen_string_literal: true

class Api::Internal::OmnibarSearchesController < Api::Internal::BaseController
  before_action :authenticate_user!

  def show
    render json: OmnibarSearchPresenter.new(pundit_user:, query: params[:query]).props
  end
end
