# frozen_string_literal: true

class EventsController < ApplicationController
  def create
    create_user_event(params[:event_name])
    render json: {
      success: true
    }
  end
end
