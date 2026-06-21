# frozen_string_literal: true

class Settings::BaseController < Sellers::BaseController
  layout "inertia"

  # The mobile app loads settings pages in a WebView with `?display=mobile_app`
  # plus an OAuth `access_token` and the shared `mobile_token`, so sign the user
  # into a web session from those params. The `is_mobile_app_web_view` prop lets
  # the frontend hide the web chrome in favor of the native UI.
  prepend_before_action :authenticate_mobile_app_web_view!
  before_action :persist_mobile_app_web_view

  inertia_share do
    {
      settings_pages: -> { settings_presenter.pages },
      is_mobile_app_web_view: params[:display] == "mobile_app" || cookies[:is_mobile_app_web_view] == "true"
    }
  end

  before_action do
    set_meta_tag(title: "Settings")
  end

  protected
    def settings_presenter
      @settings_presenter ||= SettingsPresenter.new(pundit_user:)
    end

  private
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
