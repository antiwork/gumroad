# frozen_string_literal: true

class Api::Internal::UtmLinks::UniquePermalinksController < Api::Internal::BaseController
  before_action :authenticate_user!
  after_action :verify_authorized

  def show
    authorize UtmLink, :new?

    render json: { permalink: UtmLink.generate_permalink }
  end
end
