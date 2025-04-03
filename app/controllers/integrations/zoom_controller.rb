# frozen_string_literal: true

class Integrations::ZoomController < ApplicationController
  before_action :authenticate_user!, except: [:oauth_redirect]

  def account_info
    zoom_api = ZoomApi.new
    oauth_response = zoom_api.oauth_token(params[:code], oauth_redirect_integrations_zoom_index_url)
    access_token = oauth_response.parsed_response&.dig("access_token")
    refresh_token = oauth_response.parsed_response&.dig("refresh_token")
    return render json: { success: false } unless oauth_response.success? && access_token.present? && refresh_token.present?

    user_response = zoom_api.user_info(access_token)
    return render json: { success: false } unless user_response["id"].present? && user_response["email"].present?

    render json: { success: true, user_id: user_response["id"], email: user_response["email"], access_token:, refresh_token: }
  end

  def oauth_redirect
    render inline: "", layout: "application", status: params.key?(:code) ? :ok : :bad_request
  end
end
