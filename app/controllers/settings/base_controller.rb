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
      is_mobile_app_web_view: params[:display] == "mobile_app" || session[:mobile_app_web_view] == true
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
    # the session so subsequent Inertia navigations and form submits (which drop the
    # query param) keep rendering chrome-free. Storing it in the session rather than a
    # cookie means it is cleared on logout and never leaks into a later web-only session.
    def persist_mobile_app_web_view
      return unless params[:display] == "mobile_app" && current_api_user.present?

      session[:mobile_app_web_view] = true
    end

    # Establish a web session from the OAuth token on the initial WebView load. If a
    # session already exists (a return visit or an Inertia reload), skip the token
    # check entirely so a stale or revoked token still present in the WebView URL
    # can't 401 the request before the existing session is used.
    def authenticate_mobile_app_web_view!
      return if params[:access_token].blank?
      return if user_signed_in?
      return unless ActiveSupport::SecurityUtils.secure_compare(params[:mobile_token].to_s, Api::Mobile::BaseController::MOBILE_TOKEN)

      doorkeeper_authorize! :mobile_api
      # `doorkeeper_authorize!` renders 401/403 and halts on a revoked, expired, or
      # wrong-scope token, but `current_api_user` only checks token presence (not
      # validity/scope). Without this guard `sign_in` would still establish a web
      # session from a token doorkeeper just rejected.
      return if performed?

      sign_in current_api_user if current_api_user.present?
    end
end
