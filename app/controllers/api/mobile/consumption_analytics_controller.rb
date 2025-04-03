# frozen_string_literal: true

class Api::Mobile::ConsumptionAnalyticsController < Api::Mobile::BaseController
  include CreateConsumptionEvent
  before_action { doorkeeper_authorize! :mobile_api }

  def create
    render json: { success: create_consumption_event!(params) }
  end
end
