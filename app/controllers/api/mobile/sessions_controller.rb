# frozen_string_literal: true

class Api::Mobile::SessionsController < Api::Mobile::BaseController
  before_action { doorkeeper_authorize! :mobile_api }
  skip_before_action :verify_authenticity_token, only: :create

  def create
    sign_in current_resource_owner

    render json: { success: true, user: { email: current_resource_owner.form_email } }
  end
end
