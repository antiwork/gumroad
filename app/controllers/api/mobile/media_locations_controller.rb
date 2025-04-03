# frozen_string_literal: true

class Api::Mobile::MediaLocationsController < Api::Mobile::BaseController
  include RecordMediaLocation
  before_action { doorkeeper_authorize! :mobile_api }

  def create
    render json: { success: record_media_location(params) }
  end
end
