# frozen_string_literal: true

class Api::Internal::UtmLinks::StatsController < Api::Internal::BaseController
  before_action :authenticate_user!
  after_action :verify_authorized

  def index
    authorize UtmLink

    utm_link_ids = current_seller.utm_links.by_external_ids(params[:ids]).pluck(:id)

    render json: UtmLinksStatsPresenter.new(seller: current_seller, utm_link_ids:).props
  end
end
