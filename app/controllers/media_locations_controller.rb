# frozen_string_literal: true

class MediaLocationsController < ApplicationController
  include RecordMediaLocation
  skip_before_action :check_suspended

  def create
    render json: { success: record_media_location(params) }
  end
end
