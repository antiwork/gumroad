# frozen_string_literal: true

# Shared behavior for pages that can be embedded inside the Gumroad mobile app's
# WebView. The app loads regular web pages with `?display=mobile_app` along with
# an OAuth `access_token` and the shared `mobile_token`, so we sign the user into
# a web session from those params. The `is_mobile_app_web_view` Inertia prop
# (shared globally in InertiaRendering) lets the frontend hide the app chrome in
# favor of the native UI.
module MobileAppWebView
  extend ActiveSupport::Concern

  included do
    helper_method :mobile_app_web_view?
    before_action :persist_mobile_app_web_view
  end

  private
    def mobile_app_web_view?
      params[:display] == "mobile_app" || cookies[:is_mobile_app_web_view] == "true"
    end

    # `?display=mobile_app` only arrives on the initial WebView load. Persist it in
    # a cookie so subsequent Inertia navigations and form submits (which drop the
    # query param) keep rendering chrome-free.
    def persist_mobile_app_web_view
      cookies[:is_mobile_app_web_view] = { value: "true", httponly: true } if params[:display] == "mobile_app"
    end

    def authenticate_mobile_app_web_view!
      return if params[:access_token].blank?
      return unless ActiveSupport::SecurityUtils.secure_compare(params[:mobile_token].to_s, Api::Mobile::BaseController::MOBILE_TOKEN)

      doorkeeper_authorize! :mobile_api
      sign_in current_api_user if current_api_user.present?
    end
end
