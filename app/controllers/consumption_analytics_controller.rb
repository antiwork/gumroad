# frozen_string_literal: true

class ConsumptionAnalyticsController < ApplicationController
  include CreateConsumptionEvent
  skip_before_action :check_suspended

  def create
    render json: { success: create_consumption_event!(params) }
  end
end
