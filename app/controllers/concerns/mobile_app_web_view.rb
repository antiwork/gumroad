# frozen_string_literal: true

# Signs the mobile app's embedded WebView into a web session using the OAuth
# bearer token the app appends to its first request, and shares
# is_mobile_app_web_view so pages can hide web-only chrome like the nav.
# Callers pick which actions accept the token via enable_mobile_app_web_view.
module MobileAppWebView
  extend ActiveSupport::Concern

  class_methods do
    def enable_mobile_app_web_view(only: nil)
      prepend_before_action :authenticate_mobile_app_web_view!, only: only
      before_action :persist_mobile_app_web_view, only: only

      inertia_share do
        {
          is_mobile_app_web_view: params[:display] == "mobile_app" || session[:mobile_app_web_view] == true
        }
      end
    end
  end

  private
    def persist_mobile_app_web_view
      return unless params[:display] == "mobile_app" && user_signed_in?

      session[:mobile_app_web_view] = true
    end

    def authenticate_mobile_app_web_view!
      return if params[:access_token].blank?
      return if user_signed_in?
      return unless ActiveSupport::SecurityUtils.secure_compare(params[:mobile_token].to_s, Api::Mobile::BaseController::MOBILE_TOKEN)

      doorkeeper_authorize! :mobile_api
      # Without this, a doorkeeper-rejected (revoked/expired/wrong-scope) token still signs in.
      return if performed?

      sign_in current_api_user if current_api_user.present?
    end
end
