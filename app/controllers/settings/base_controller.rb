# frozen_string_literal: true

class Settings::BaseController < Sellers::BaseController
  layout "inertia"

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
