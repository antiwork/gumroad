# frozen_string_literal: true

class Oauth::AccessTokensController < Sellers::BaseController
  before_action :set_application

  def create
    authorize [:settings, :authorized_applications, @application]
    access_token = @application.get_or_generate_access_token

    render json: { success: true, token: access_token.token }
  end

  private
    def set_application
      @application = current_seller.oauth_applications.alive.find_by_external_id(params[:application_id])
      return if @application.present?

      render json: { success: false, message: "Application not found or you don't have the permissions to modify it." }, status: :not_found
    end
end
