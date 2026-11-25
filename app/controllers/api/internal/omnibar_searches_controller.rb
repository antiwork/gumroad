# frozen_string_literal: true

class Api::Internal::OmnibarSearchesController < Api::Internal::BaseController
  before_action :authenticate_user!

  def show
    group = params[:group].to_s
    return head :bad_request unless OmnibarSearchPresenter::GROUPS.include?(group)

    render json: OmnibarSearchPresenter.new(pundit_user:, query: params[:query], group:).props
  end
end
