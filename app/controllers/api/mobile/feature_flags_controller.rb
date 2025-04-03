# frozen_string_literal: true

class Api::Mobile::FeatureFlagsController < Api::Mobile::BaseController
  before_action { doorkeeper_authorize! :mobile_api }

  def show
    render json: { enabled_for_user: Feature.active?(params[:id], current_resource_owner) }
  end
end
