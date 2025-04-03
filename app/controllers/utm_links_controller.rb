# frozen_string_literal: true

class UtmLinksController < Sellers::BaseController
  before_action :set_body_id_as_app

  def index
    authorize UtmLink
  end

  private
    def set_title
      @title = "UTM Links"
    end
end
