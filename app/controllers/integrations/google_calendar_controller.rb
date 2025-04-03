# frozen_string_literal: true

class Integrations::GoogleCalendarController < ApplicationController
  before_action :authenticate_user!, except: [:oauth_redirect]

  def account_info
    gcal_api = GoogleCalendarApi.new
    oauth_response = gcal_api.oauth_token(params[:code], oauth_redirect_integrations_google_calendar_index_url)
    access_token = oauth_response.parsed_response&.dig("access_token")
    refresh_token = oauth_response.parsed_response&.dig("refresh_token")
    return render json: { success: false } unless oauth_response.success? && access_token.present? && refresh_token.present?

    user_info_response = gcal_api.user_info(access_token)
    email = user_info_response.parsed_response&.dig("email")
    return render json: { success: false } unless user_info_response.success? && email.present?

    render json: { success: true, access_token:, refresh_token:, email: }
  end

  def calendar_list
    gcal_api = GoogleCalendarApi.new
    calendar_list_response = gcal_api.calendar_list(params[:access_token])

    if calendar_list_response.code === 401
      refresh_token_response = gcal_api.refresh_token(params[:refresh_token])
      access_token = refresh_token_response.parsed_response&.dig("access_token")
      return render json: { success: false } unless refresh_token_response.success? && access_token.present?

      calendar_list_response = gcal_api.calendar_list(access_token)
    end

    return render json: { success: false } unless calendar_list_response.success?

    render json: {
      success: true,
      calendar_list: calendar_list_response.parsed_response["items"].map { |c| c.slice("id", "summary") }
    }
  end

  def oauth_redirect
    render inline: "", layout: "application", status: params.key?(:code) ? :ok : :bad_request
  end
end
